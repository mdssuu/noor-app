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
    if (!env.GEMINI_API_KEY) return reply({ error: 'OCR service is not configured' }, 503);

    const hint = typeof body.hint === 'string' && body.hint.trim()
      ? ` The board may be labelled: ${body.hint.trim()}.`
      : '';
    const model = env.GEMINI_MODEL || 'gemini-2.5-flash';
    const upstream = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(env.GEMINI_API_KEY)}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: PROMPT }] },
          contents: [{ parts: [
            { text: `Read the Jamaat times from this board.${hint}` },
            { inlineData: { mimeType: 'image/jpeg', data: body.image } },
          ] }],
          generationConfig: { responseMimeType: 'application/json', temperature: 0 },
        }),
      },
    );
    const raw = await upstream.text();
    if (!upstream.ok) return reply({ error: 'Gemini request failed' }, 502);
    let json;
    try { json = JSON.parse(raw); } catch (_) { return reply({ error: 'Invalid Gemini response' }, 502); }
    const result = json?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof result !== 'string' || !result.trim()) return reply({ error: 'Empty Gemini response' }, 502);
    return new Response(result, { status: 200, headers: corsHeaders() });
  },
};
