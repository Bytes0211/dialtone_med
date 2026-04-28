const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8'
};

// Per-isolate in-memory rate limiter: max 5 submissions per IP per 60 seconds.
const RATE_LIMIT_MAX = 5;
const RATE_LIMIT_WINDOW_MS = 60_000;
const rateLimitMap = new Map();

function isRateLimited(ip) {
  const now = Date.now();
  const entry = rateLimitMap.get(ip);
  if (!entry || now - entry.windowStart >= RATE_LIMIT_WINDOW_MS) {
    rateLimitMap.set(ip, { windowStart: now, count: 1 });
    return false;
  }
  entry.count += 1;
  return entry.count > RATE_LIMIT_MAX;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    return routeRequest(request, env, url);
  }
};

async function routeRequest(request, env, url) {
  // Explicit handlers for known dynamic paths.
  if (url.pathname === '/robots.txt') {
    return handleRobots(url);
  }

  if (url.pathname === '/favicon.ico') {
    return handleFavicon(request, env);
  }

  if (url.pathname === '/.well-known/security.txt') {
    return handleSecurityTxt();
  }

  if (url.pathname === '/sitemap.xml') {
    return handleSitemap(url);
  }

  if (url.pathname === '/api/contact') {
    return handleContact(request, env);
  }

  // For all paths not explicitly handled above, delegate to the assets binding
  // and normalize missing lookups to 404.
  return handleAssetRequest(request, env);
}

async function handleAssetRequest(request, env) {
  try {
    const response = await env.ASSETS.fetch(request);

    // Missing static assets can surface as 500 from the assets binding;
    // normalize those to 404 so crawlers and clients get the correct status.
    if (response.status === 500 && isLookupMethod(request.method)) {
      return notFoundResponse();
    }

    return response;
  } catch (error) {
    // If asset resolution throws on an unmatched path, return 404 rather
    // than exposing an internal failure.
    if (isLookupMethod(request.method)) {
      console.log('ASSETS fetch lookup error:', String(error));
      return notFoundResponse();
    }

    throw error;
  }
}

function isLookupMethod(method) {
  return method === 'GET' || method === 'HEAD';
}

function notFoundResponse() {
  return new Response('Not Found', {
    status: 404,
    headers: {
      'content-type': 'text/plain; charset=utf-8'
    }
  });
}

function handleRobots(url) {
  const sitemap = `${url.origin}/sitemap.xml`;

  const body = [
    'User-agent: *',
    'Allow: /',
    'Disallow: /admin/',
    'Disallow: /api/',
    '',
    'User-agent: GPTBot',
    'Disallow: /',
    '',
    `Sitemap: ${sitemap}`,
    ''
  ].join('\n');

  return new Response(body, {
    headers: {
      'content-type': 'text/plain; charset=utf-8'
    }
  });
}

async function handleFavicon(request, env) {
  // Browsers default-request `/favicon.ico`; rewrite to the SVG asset.
  // Modern browsers honor the HTML `<link rel="icon" type="image/svg+xml">`
  // hints and skip the `.ico` request entirely; this path handles the
  // legacy fallback case and ensures the response still carries the
  // correct `image/svg+xml` content-type from the assets binding.
  const faviconUrl = new URL(request.url);
  faviconUrl.pathname = '/images/favicon.svg';
  const faviconRequest = new Request(faviconUrl.toString(), request);
  try {
    const response = await env.ASSETS.fetch(faviconRequest);
    if (response.status === 500 && isLookupMethod(request.method)) {
      return notFoundResponse();
    }
    return response;
  } catch (error) {
    if (isLookupMethod(request.method)) {
      console.log('ASSETS favicon lookup error:', String(error));
      return notFoundResponse();
    }
    throw error;
  }
}

function handleSecurityTxt() {
  const body = [
    'Contact: mailto:security@bytestreams.ai',
    'Expires: 2027-04-23T00:00:00.000Z',
    'Preferred-Languages: en',
    ''
  ].join('\n');

  return new Response(body, {
    headers: {
      'content-type': 'text/plain; charset=utf-8'
    }
  });
}

function handleSitemap(url) {
  const pages = ['/', '/privacy.html', '/terms.html', '/hippa.html'];
  const body = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...pages.map((path) => `  <url><loc>${escapeXml(`${url.origin}${path}`)}</loc></url>`),
    '</urlset>',
    ''
  ].join('\n');

  return new Response(body, {
    headers: {
      'content-type': 'application/xml; charset=utf-8'
    }
  });
}

async function handleContact(request, env) {
  if (request.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (isRateLimited(clientIp)) {
    return jsonResponse({ error: 'Too many requests. Please try again later.' }, 429);
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: 'Invalid request body' }, 400);
  }

  const name = normalizeText(payload.name, 120);
  const company = normalizeText(payload.company, 160);
  const email = normalizeText(payload.email, 254);
  const message = normalizeText(payload.message, 5000);
  const honeypot = normalizeText(payload.website || '', 200);

  if (honeypot) {
    return jsonResponse({ ok: true });
  }

  if (!name || !company || !email || !message) {
    return jsonResponse({ error: 'Please fill out all fields.' }, 400);
  }

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return jsonResponse({ error: 'Please provide a valid email address.' }, 400);
  }

  // Runtime config health for DB persistence.
  const supabaseDbKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_KEY;
  const hasSupabaseUrl = Boolean(env.SUPABASE_URL);
  const hasSupabaseDbKey = Boolean(supabaseDbKey);
  if (!hasSupabaseUrl || !hasSupabaseDbKey) {
    console.log('Contact config health:', JSON.stringify({
      hasSupabaseUrl,
      hasSupabaseDbKey,
      hasServiceRoleKey: Boolean(env.SUPABASE_SERVICE_ROLE_KEY),
      hasFallbackKey: Boolean(env.SUPABASE_KEY)
    }));

    return jsonResponse({
      error: 'Form configuration is incomplete. Please contact support.'
    }, 503);
  }

  // Persist first so a successful response always implies a stored row.
  try {
    await saveToSupabase({
      email,
      name,
      company,
      comment: message,
      supabaseUrl: env.SUPABASE_URL,
      supabaseKey: supabaseDbKey
    });
  } catch (error) {
    console.log('Supabase save error:', String(error));
    return jsonResponse({
      error: 'We could not save your submission. Please try again shortly.'
    }, 502);
  }

  const destinationEmail = env.CONTACT_EMAIL;
  if (!destinationEmail) {
    return jsonResponse({ error: 'Contact destination is not configured.' }, 503);
  }

  if (!env.RESEND_API_KEY) {
    // Surfaces in observability; client-side error keeps submitters in
    // the form rather than bouncing them to a mail app.
    console.log('Contact form unavailable: RESEND_API_KEY secret is not set.');
    return jsonResponse({
      error: 'Contact form is temporarily unavailable. Please try again shortly.'
    }, 503);
  }

  const result = await forwardToResend({
    destinationEmail,
    siteName: env.SITE_NAME,
    name,
    company,
    email,
    message,
    apiKey: env.RESEND_API_KEY
  });

  if (!result.ok) {
    // Log provider response for CF Workers observability — rate-limit
    // reasons, invalid-key errors, and domain-unverified states all
    // surface here. Details stay server-side.
    console.log('Resend failure:', JSON.stringify({
      httpStatus: result.httpStatus,
      errorName: result.errorName,
      errorMessage: result.errorMessage
    }));

    return jsonResponse({
      error: 'Message delivery failed. Please try again shortly.'
    }, 502);
  }

  return jsonResponse({ ok: true });
}

async function forwardToResend({ destinationEmail, siteName, name, company, email, message, apiKey }) {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`
    },
    body: JSON.stringify({
      // Sender lives on the shared `send.bytestreams.ai` Resend domain
      // (see developer/resend-notes or the project plan memo). `hello@`
      // local-part kept in sync with the recipient mailbox for symmetry.
      from: `${siteName} <contact@send.bytestreams.ai>`,
      to: [destinationEmail],
      // Reply-To: the submitter's address so hitting Reply in Gmail goes
      // straight back to the person who filled out the form. Passed as a
      // single-element array to match Resend's documented canonical form;
      // the regex check in `handleContact` already rejects display-name /
      // bracketed-address syntax (whitespace and `<>` fail the anchored
      // `[^\s@]+@[^\s@]+\.[^\s@]+` pattern), so `email` is a bare address.
      reply_to: [email],
      subject: `${siteName} Contact: ${company} (${name})`,
      text: buildTextBody({ siteName, name, company, email, message }),
      html: buildHtmlBody({ siteName, name, company, email, message })
    })
  });

  let payload = null;
  try {
    payload = await response.json();
  } catch {
    payload = null;
  }

  // Resend success returns `{ id: "<resend_message_id>" }`; errors return
  // `{ statusCode, name, message }`. Treat presence of `id` as the ok signal.
  const ok = response.ok && payload !== null && typeof payload.id === 'string';

  return {
    ok,
    httpStatus: response.status,
    errorName: payload && payload.name ? String(payload.name) : '',
    errorMessage: payload && payload.message ? String(payload.message) : ''
  };
}

function buildTextBody({ siteName, name, company, email, message }) {
  return [
    `New ${siteName} contact form submission`,
    '',
    `Contact: ${name}`,
    `Company: ${company}`,
    `Email: ${email}`,
    '',
    message,
    '',
    '---',
    `Submitted via the ${siteName} contact form.`,
    'Reply directly to this email to respond to the sender.'
  ].join('\n');
}

function buildHtmlBody({ siteName, name, company, email, message }) {
  const safeSite = escapeHtml(siteName);
  const safeName = escapeHtml(name);
  const safeCompany = escapeHtml(company);
  const safeEmail = escapeHtml(email);
  const safeMessage = escapeHtml(message);
  return [
    '<!doctype html>',
    '<html>',
    '<body style="font-family: -apple-system, BlinkMacSystemFont, \'Segoe UI\', sans-serif; max-width: 560px; margin: 0 auto; padding: 24px; color: #1a1410;">',
    `<h2 style="margin: 0 0 16px 0;">New ${safeSite} contact form submission</h2>`,
    `<p style="margin: 0 0 8px 0;"><strong>Contact:</strong> ${safeName}</p>`,
    `<p style="margin: 0 0 8px 0;"><strong>Company:</strong> ${safeCompany}</p>`,
    `<p style="margin: 0 0 8px 0;"><strong>Email:</strong> <a href="mailto:${safeEmail}" style="color: #c8391a;">${safeEmail}</a></p>`,
    '<hr style="border: none; border-top: 1px solid #ebe3d5; margin: 16px 0;">',
    `<div style="white-space: pre-wrap; line-height: 1.5;">${safeMessage}</div>`,
    '<hr style="border: none; border-top: 1px solid #ebe3d5; margin: 24px 0 16px 0;">',
    `<p style="margin: 0; font-size: 12px; color: #6b5d4f;">Submitted via the ${safeSite} contact form. Reply directly to this email to respond to the sender.</p>`,
    '</body>',
    '</html>'
  ].join('');
}

async function saveToSupabase({ email, name, company, comment, supabaseUrl, supabaseKey }) {
  const endpoint = `${supabaseUrl}/rest/v1/waitlist_submissions`;
  const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${supabaseKey}`,
    'apikey': supabaseKey,
    'Prefer': 'return=representation'
  };
  const basePayload = {
    email,
    name,
    restaurant_name: company,
    campaign: 'Med Launch',
    comment: comment || null,
    created_at: new Date().toISOString()
  };

  // Prefer the canonical DialTone.Med column while preserving compatibility
  // with older/shared tables that only have restaurant_name.
  let response = await fetch(endpoint, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      ...basePayload,
      company_name: company
    })
  });

  if (!response.ok) {
    const errorText = await response.text();
    const companyColumnMissing = response.status === 400 && /company_name/i.test(errorText);
    if (companyColumnMissing) {
      response = await fetch(endpoint, {
        method: 'POST',
        headers,
        body: JSON.stringify(basePayload)
      });

      if (!response.ok) {
        const fallbackErrorText = await response.text();
        throw new Error(`Supabase insert failed (${response.status}): ${fallbackErrorText}`);
      }

      return await response.json();
    }

    throw new Error(`Supabase insert failed (${response.status}): ${errorText}`);
  }

  return await response.json();
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function normalizeText(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function escapeXml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS
  });
}
