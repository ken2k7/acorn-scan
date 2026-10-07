import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { serve } from '@hono/node-server'
import { GoogleGenAI } from '@google/genai'

const app = new Hono()
// The Flutter web app runs on a different port, so the browser needs CORS.
app.use('/*', cors())

// ----------------------------------------------------------- what we ask for

const SYSTEM = `You transcribe pharmacy prescription labels into structured data.

Rules:
- Report only what is printed. Never infer, never add medical knowledge.
- If a field is not printed, return null. Never guess.
- source_quote is the exact text the medication came from, copied verbatim.
- Expand local dosing notation: 1-0-0 once daily (morning), 0-0-1 once daily (night),
  1-0-1 twice daily, 1-1-1 three times daily. OM = morning, ON = night, BD = twice daily,
  TDS = three times daily, QDS = four times daily, PRN = as needed.
- times_of_day only if the label says when (morning, night, etc.).
- stopped: true ONLY if the label explicitly says to stop or discontinue this
  medication (e.g. "stop", "discontinue", "cease"). Otherwise false. Never infer a
  stop from a drug simply being absent, or from a quantity running out.
- duration_days only if the label states how long to take it. A dispensed quantity
  ("x 60 tabs") is NOT a duration.
- Do not extract the patient's name, ID number or address.
- Set confidence below 0.8 for anything blurry, handwritten, ambiguous or cut off.`

// Gemini's schema format: UPPERCASE types, `nullable: true` for optional values.
const S = (type: string, extra: object = {}) => ({ type, ...extra })
const N = (type: string, extra: object = {}) => ({ type, nullable: true, ...extra })

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    dispensed_date: N('STRING', { description: 'ISO date if printed' }),
    pharmacy: N('STRING'),
    medications: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          drug_name: S('STRING'),
          strength: N('STRING'),
          form: N('STRING', { enum: ['tablet', 'capsule', 'liquid', 'inhaler', 'cream', 'other'] }),
          dose_quantity: N('NUMBER'),
          dose_unit: N('STRING'),
          frequency_as_written: N('STRING'),
          times_per_day: N('NUMBER'),
          times_of_day: { type: 'ARRAY', items: S('STRING', { enum: ['morning', 'midday', 'evening', 'bedtime'] }) },
          with_food: N('STRING', { enum: ['before_food', 'with_food', 'after_food', 'empty_stomach'] }),
          prn: S('BOOLEAN'),
          stopped: S('BOOLEAN'),
          duration_days: N('NUMBER'),
          quantity_dispensed: N('STRING'),
          special_instructions: N('STRING'),
          source_quote: S('STRING'),
          confidence: S('NUMBER'),
        },
        required: ['drug_name', 'prn', 'stopped', 'source_quote', 'confidence'],
      },
    },
  },
  required: ['medications'],
}

// ------------------------------------------------------------- reading

// Model names go stale (a pinned one can start returning 404), so try a list.
const MODELS = ['gemini-3.6-flash', 'gemini-flash-latest', 'gemini-3.5-flash']
const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY })

async function readLabel(bytes: Buffer, mimeType: string): Promise<unknown> {
  let lastErr: unknown
  for (const model of MODELS) {
    try {
      const res = await ai.models.generateContent({
        model,
        contents: [{ role: 'user', parts: [
          { inlineData: { mimeType, data: bytes.toString('base64') } },
          { text: 'Transcribe this prescription label.' },
        ] }],
        config: {
          systemInstruction: SYSTEM,
          responseMimeType: 'application/json',
          responseSchema: SCHEMA,
          temperature: 0, // transcription, not creativity
        },
      })
      return JSON.parse(res.text ?? '{}')
    } catch (err) {
      lastErr = err
      console.warn(`${model} failed, trying next`)
    }
  }
  throw lastErr
}

// ------------------------------------------------------------- checking

// Never trust model output blindly: keep only well-formed items.
function validate(raw: any) {
  const meds = Array.isArray(raw?.medications) ? raw.medications : []
  return meds
    .filter((m: any) => typeof m?.drug_name === 'string' && m.drug_name.trim())
    .map((m: any) => ({
      ...m,
      prn: m.prn === true,
      stopped: m.stopped === true,
      times_of_day: Array.isArray(m.times_of_day) ? m.times_of_day : [],
      confidence: typeof m.confidence === 'number' ? m.confidence : 0.5,
    }))
}

// ------------------------------------------------------------- scheduling

const DEFAULT_TIMES: Record<number, string[]> = {
  1: ['08:00'],
  2: ['08:00', '20:00'],
  3: ['08:00', '14:00', '20:00'],
  4: ['08:00', '12:00', '16:00', '20:00'],
}
const SLOT: Record<string, string> = {
  morning: '08:00', midday: '13:00', evening: '20:00', bedtime: '22:00',
}

function buildSchedule(m: any) {
  // A drug the label says to stop is never scheduled, whatever else it says.
  if (m.stopped) return { times: [], times_assumed: false, needs_review: false, reason: 'Doctor says to stop — not added to schedule' }

  if (m.prn) return { times: [], times_assumed: false, needs_review: false, reason: 'Taken only when needed' }

  const n = m.times_per_day
  if (!n || !DEFAULT_TIMES[n]) {
    return { times: [], times_assumed: false, needs_review: true, reason: 'How often is not clear on the label' }
  }
  if (m.times_of_day.length && m.times_of_day.length !== n) {
    return { times: [], times_assumed: false, needs_review: true, reason: 'Times of day do not match how often' }
  }

  const printed = m.times_of_day.length > 0
  const times = printed ? m.times_of_day.map((t: string) => SLOT[t]) : DEFAULT_TIMES[n]
  const low = m.confidence < 0.8
  return {
    times,
    times_assumed: !printed,
    needs_review: low,
    reason: low ? 'The label was hard to read here' : null,
  }
}

// ------------------------------------------------------------- the route

app.post('/scan', async (c) => {
  const body = await c.req.parseBody()
  const file = body['file']
  if (!(file instanceof File)) return c.json({ error: 'No image was uploaded.' }, 400)
  if (file.size > 12 * 1024 * 1024) return c.json({ error: 'That image is too large (max 12 MB).' }, 413)

  const mime = file.type && file.type !== 'application/octet-stream'
    ? file.type
    : file.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg'

  try {
    const bytes = Buffer.from(await file.arrayBuffer())
    const raw: any = await readLabel(bytes, mime)
    const medications = validate(raw).map((m: any) => ({ ...m, schedule: buildSchedule(m) }))
    return c.json({ dispensed_date: raw?.dispensed_date ?? null, pharmacy: raw?.pharmacy ?? null, medications })
  } catch (err) {
    console.error(err)
    return c.json({ error: 'Could not read that label. Try a clearer photo.' }, 502)
  }
})

app.get('/', (c) => c.text('acorn-scan server is running. POST an image to /scan.'))

serve({ fetch: app.fetch, port: 8787 })
console.log('Server on http://localhost:8787')
