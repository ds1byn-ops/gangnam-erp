import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// 강남펄스 견적 알림톡 발송 (Solapi). 시크릿은 Supabase Edge Function Secrets(SOLAPI_*)에 저장.
// 설정 전에는 configured:false 로 안전하게 응답 → 프론트가 복사 방식으로 폴백.

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randSalt(n = 32): string {
  const a = new Uint8Array(n);
  crypto.getRandomValues(a);
  return toHex(a.buffer).slice(0, n);
}
async function hmacSha256(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return toHex(sig);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const API_KEY = Deno.env.get("SOLAPI_API_KEY") ?? "";
  const API_SECRET = Deno.env.get("SOLAPI_API_SECRET") ?? "";
  const PFID = Deno.env.get("SOLAPI_PFID") ?? "";
  const SENDER = Deno.env.get("SOLAPI_SENDER") ?? "";
  const ENV_TEMPLATE = Deno.env.get("SOLAPI_TEMPLATE_ID") ?? "";

  if (!API_KEY || !API_SECRET || !PFID || !SENDER) {
    return json({ ok: false, configured: false, error: "알림톡 미설정: Supabase Secrets(SOLAPI_API_KEY/SECRET/PFID/SENDER)를 등록하세요." });
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "invalid json" }, 400); }

  const to = String(body.to ?? "").replace(/[^0-9]/g, "");
  const templateId = String(body.templateId ?? "") || ENV_TEMPLATE;
  const variables = (body.variables ?? {}) as Record<string, string>;
  if (!to) return json({ ok: false, error: "수신번호(to)가 없습니다." }, 400);
  if (!templateId) return json({ ok: false, error: "templateId가 없습니다(본문 또는 SOLAPI_TEMPLATE_ID)." }, 400);

  const date = new Date().toISOString();
  const salt = randSalt();
  const signature = await hmacSha256(API_SECRET, date + salt);
  const auth = `HMAC-SHA256 apiKey=${API_KEY}, date=${date}, salt=${salt}, signature=${signature}`;

  const payload = {
    message: {
      to,
      from: SENDER.replace(/[^0-9]/g, ""),
      kakaoOptions: { pfId: PFID, templateId, variables, disableSms: false },
    },
  };

  let resp: Response;
  try {
    resp = await fetch("https://api.solapi.com/messages/v4/send", {
      method: "POST",
      headers: { "Authorization": auth, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    return json({ ok: false, error: "solapi 연결 실패", detail: String(e) });
  }
  const result = await resp.json().catch(() => ({}));
  if (!resp.ok) return json({ ok: false, error: "solapi 오류", detail: result });
  return json({ ok: true, result });
});
