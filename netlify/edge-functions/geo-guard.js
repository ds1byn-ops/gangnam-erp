const BLOCK = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>접속 제한 / Access Restricted</title><style>body{margin:0;font-family:sans-serif;background:#0f4d33;color:#fff;display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center}.b{max-width:440px;padding:32px}.b h1{font-size:22px;margin:0 0 14px}.b p{opacity:.85;line-height:1.8;font-size:14px}</style></head><body><div class="b"><h1>접속이 제한된 지역입니다</h1><p>该地区暂不支持访问<br>Access from your region is restricted.<br>관리자에게 문의해 주세요.</p></div></body></html>`;
export default async (request, context) => {
  try {
    const country = (context.geo && context.geo.country && context.geo.country.code) || '';
    if (country === 'KR') return;
    let enabled = true, allowed = ['KR'];
    try {
      const res = await fetch('https://utbhlvybdutepnkvboko.supabase.co/rest/v1/geo_config?id=eq.1&select=enabled,allowed_countries', { headers: { apikey: 'sb_publishable_LdLPNdjrD49iuOVLK8KVEA_SGgg9mkj' } });
      const j = await res.json();
      if (Array.isArray(j) && j[0]) { enabled = j[0].enabled; allowed = j[0].allowed_countries || ['KR']; }
    } catch (e) { return; }
    if (!enabled) return;
    if (!country) return;
    if (allowed.indexOf(country) !== -1) return;
    return new Response(BLOCK, { status: 403, headers: { 'content-type': 'text/html; charset=utf-8' } });
  } catch (e) { return; }
};
export const config = { path: '/*' };
