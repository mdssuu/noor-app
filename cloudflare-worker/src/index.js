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

function responseText(json, provider) {
  if (provider === 'gemini') {
    return json?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  }
  const content = json?.choices?.[0]?.message?.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((part) => part?.text || '').join('');
  return json?.choices?.[0]?.message?.reasoning || '';
}

function extractTimes(text) {
  if (typeof text !== 'string') return {};
  const result = {};
  const labels = 'fajr|dhuhr|asr|maghrib|isha|juma|jumuah|friday';
  const re = new RegExp(`(?:[\\"']?(${labels})[\\"']?)(?:\\s|_|-)*[:=：-]?(?:\\s|：)*([0-9]{1,2})\\s*[:.]\\s*([0-9]{2})\\s*(am|pm)?`, 'ig');
  for (const match of text.matchAll(re)) {
    let key = match[1].toLowerCase();
    if (key === 'jumuah' || key === 'friday') key = 'juma';
    let hour = Number(match[2]);
    const minute = Number(match[3]);
    const meridiem = (match[4] || '').toLowerCase();
    if (meridiem === 'pm' && hour < 12) hour += 12;
    if (meridiem === 'am' && hour === 12) hour = 0;
    if (hour <= 23 && minute <= 59) result[key] = `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  }
  return result;
}

function normalizeResult(text) {
  if (typeof text !== 'string') return null;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      const object = JSON.parse(text.slice(start, end + 1));
      const times = extractTimes(JSON.stringify(object));
      if (Object.keys(times).length) return { name: object.name || '', ...times };
    } catch (_) {}
  }
  const times = extractTimes(text);
  return Object.keys(times).length ? times : null;
}

function containsPrayerTime(text) {
  return Boolean(normalizeResult(text));
}

async function usableResponse(response, provider) {
  if (!response || !response.ok) return false;
  try {
    const json = JSON.parse(await response.clone().text());
    return containsPrayerTime(responseText(json, provider));
  } catch (_) {
    return false;
  }
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
    const extractedText = typeof body.extractedText === 'string' && body.extractedText.trim()
      ? ` On-device OCR extracted this possibly noisy text; use it as a cross-check, not as truth:\n${body.extractedText.slice(0, 4000)}`
      : '';
    const model = env.GEMINI_MODEL || 'gemini-2.5-flash';
    const prompt = `Read the Jamaat times from this board.${hint}${extractedText}`;
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
    // Try several currently-listed free vision routes; free pools are shared
    // and any one of them may be temporarily rate-limited.
    if ((!upstream || !(await usableResponse(upstream, provider))) && hasOpenRouter) {
      provider = 'openrouter';
      const models = env.OPENROUTER_MODEL
        ? [env.OPENROUTER_MODEL]
        : [
            // Free vision routes only; never silently use a paid model.
            'google/gemma-4-26b-a4b-it:free',
            'google/gemma-4-31b-it:free',
            'nvidia/nemotron-3.5-super-vl:free',
            'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
            'openrouter/free',
          ];
      for (const modelName of models) {
        const candidate = await fetch('https://openrouter.ai/api/v1/chat/completions', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${env.OPENROUTER_API_KEY}`,
            'Content-Type': 'application/json',
            'HTTP-Referer': 'https://noor.app',
            'X-Title': 'Noor Masjid Time',
          },
          body: JSON.stringify({
            model: modelName,
            messages: [{ role: 'user', content: [
              { type: 'text', text: `${PROMPT}\n${prompt}` },
              { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${body.image}` } },
            ] }],
            temperature: 0,
            max_tokens: 512,
          }),
        });
        upstream = candidate;
        if (await usableResponse(candidate, 'openrouter')) break;
      }
    }

    if (!upstream || !(await usableResponse(upstream, provider))) {
      return reply({ error: `No provider returned usable prayer times`, provider }, 502);
    }
    let raw = await upstream.text();
    if (provider === 'openrouter') {
      try {
        const parsed = JSON.parse(raw);
        const content = parsed?.choices?.[0]?.message?.content;
        if (!content && parsed?.choices?.[0]?.message?.reasoning) {
          raw = JSON.stringify({
            choices: [{ message: { content: parsed.choices[0].message.reasoning } }],
          });
        }
      } catch (_) {}
    }
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
    if (typeof result !== 'string' || !result.trim()) {
      console.error(`${provider} empty response`, raw.slice(0, 1000));
      return reply({ error: `Empty ${provider} response`, details: raw.slice(0, 500) }, 502);
    }
    const normalized = normalizeResult(result);
    if (!normalized) return reply({ error: `No usable prayer times in ${provider} response` }, 502);
    return new Response(JSON.stringify(normalized), { status: 200, headers: corsHeaders() });
  },
};
