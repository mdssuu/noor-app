const PROMPT = `You transcribe photographs of masjid (mosque) prayer-time boards.
Reply with STRICT JSON only. No prose, markdown, or commentary.
Always return JAMAAT times, never START/AZAN times. If only one time is printed, treat it as Jamaat.
Use 24-hour HH:MM values internally. Omit keys the board does not show; do not invent values.
Schema: {"name":"string","fajr":"HH:MM","dhuhr":"HH:MM","asr":"HH:MM","maghrib":"HH:MM","isha":"HH:MM","juma":"HH:MM"}`;

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
  };
}

function reply(body, status = 200) {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status,
    headers: corsHeaders(),
  });
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: corsHeaders() });
    if (request.method !== 'POST') return reply({ error: 'POST required' }, 405);

    let body;
    try { body = await request.json(); } catch (_) { return reply({ error: 'Invalid JSON' }, 400); }
    if (typeof body.image !== 'string' || body.image.length < 100) {
      return reply({ error: 'image is required' }, 400);
    }
    const hasGemini = Boolean(env.GEMINI_API_KEY);
    const hasOpenRouter = Boolean(env.OPENROUTER_API_KEY);
    if (!hasGemini && !hasOpenRouter) {
      return reply({ error: 'OCR service is not configured' }, 503);
    }

    const hint = typeof body.hint === 'string' && body.hint.trim()
      ? ` The board may be labelled: ${body.hint.trim()}.`
      : '';
    const model = env.GEMINI_MODEL || 'gemini-3.8-flash';
    const prompt = `Read the Jamaat times from this board.${hint}`;
    let upstream;
    let provider = 'gemini';
    if (hasGemini) {
      upstream = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(env.GEMINI_API_KEY)}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: PROMPT }] },
            contents: [{ parts: [
              { text: prompt },
              { inlineData: { mimeType: 'image/jpeg', data: body.image } },
            ] }],
            generationConfig: { responseMimeType: 'application/json', temperature: 0, maxOutputTokens: 256 },
          }),
        },
      );
    }

    // OpenRouter is used only when Gemini is unavailable or quota-limited.
    if ((!upstream || !upstream.ok) && hasOpenRouter) {
      provider = 'openrouter';
      upstream = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${env.OPENROUTER_API_KEY}`,
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://noor.app',
          'X-Title': 'Noor Masjid Time',
        },
        body: JSON.stringify({
          model: env.OPENROUTER_MODEL || 'openrouter/free',
          messages: [{ role: 'user', content: [
            { type: 'text', text: `${PROMPT}\n${prompt}` },
            { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${body.image}` } },
          ] }],
          temperature: 0,
          max_tokens: 256,
        }),
      });
    }

    const raw = await upstream.text();
    if (!upstream.ok) {
      console.error('Gemini upstream failure', upstream.status, raw.slice(0, 500));
      return reply({
        error: 'Gemini request failed',
        upstreamStatus: upstream.status,
        provider,
        details: raw.slice(0, 500),
      }, 502);
    }
    let json;
    try { json = JSON.parse(raw); } catch (_) { return reply({ error: `Invalid ${provider} response` }, 502); }
    const openRouterContent = json?.choices?.[0]?.message?.content;
    const result = provider === 'gemini'
      ? json?.candidates?.[0]?.content?.parts?.[0]?.text
      : typeof openRouterContent === 'string'
          ? openRouterContent
          : Array.isArray(openRouterContent)
              ? openRouterContent.map((part) => part?.text || '').join('')
              : '';
    if (typeof result !== 'string' || !result.trim()) return reply({ error: `Empty ${provider} response` }, 502);
    return new Response(result, { status: 200, headers: corsHeaders() });
  },
};
