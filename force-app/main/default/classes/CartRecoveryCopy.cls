// DEPRECATED: superseded by the agent-writes-the-email + EmailService.send_email path.
// Retained as a deterministic fallback only; do not extend. See CHAT-AGENT-ORCHESTRATION-DESIGN (D-9).
/**
 * CartRecoveryCopy — AI-written "come back to your cart" email (Einstein Models API),
 * with a deterministic fallback. AI behaves like a callout → call BEFORE any DML.
 */
public without sharing class CartRecoveryCopy {
    private static final String MODEL = 'sfdc_ai__DefaultGPT4OmniMini';
    private static final String CART = 'https://deepskyblue-deer-920559.hostingersite.com/cart';

    public static String generate(String firstName, String heroImg, Integer pct, String code, Date expiry) {
        Map<String,String> ai = tryAi(firstName);
        String headline = ai.get('headline');
        String pitch = ai.get('pitch');
        if (String.isBlank(headline)) headline = 'Your cart is still warm, ' + firstName + ' ☕';
        if (String.isBlank(pitch)) pitch = 'You left some great coffee behind — finish checking out and it is yours, fresh-roasted and on its way.';
        return assemble(headline, pitch, heroImg, pct, code, expiry);
    }
    private static Map<String,String> tryAi(String firstName) {
        Map<String,String> out = new Map<String,String>();
        if (Test.isRunningTest()) return out;
        try {
            String prompt = 'You are a playful, warm email copywriter for "Kwitko Coffee Co." A shopper named ' + firstName +
                ' left coffee in their cart without checking out. Return ONLY JSON (no code fences) with keys ' +
                '"headline" (max 8 words, gently urgent, at most one emoji) and "pitch" (2 short irresistible ' +
                'sentences nudging them to complete the order, evoking fresh coffee aroma; do not invent prices). JSON only.';
            aiplatform.ModelsAPI m = new aiplatform.ModelsAPI();
            aiplatform.ModelsAPI.createGenerations_Request req = new aiplatform.ModelsAPI.createGenerations_Request();
            req.modelName = MODEL;
            aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
            body.prompt = prompt; req.body = body;
            aiplatform.ModelsAPI.createGenerations_Response res = m.createGenerations(req);
            String text = res?.Code200?.generation?.generatedText;
            if (String.isBlank(text)) return out;
            text = text.trim();
            if (text.startsWith('```')) { text = text.replaceFirst('(?s)^```[a-zA-Z]*',''); if (text.endsWith('```')) text = text.substring(0, text.length()-3); }
            Integer s = text.indexOf('{'), e = text.lastIndexOf('}');
            if (s < 0 || e <= s) return out;
            Map<String,Object> j = (Map<String,Object>) JSON.deserializeUntyped(text.substring(s, e+1));
            if (j.get('headline') != null) out.put('headline', String.valueOf(j.get('headline')));
            if (j.get('pitch') != null) out.put('pitch', String.valueOf(j.get('pitch')));
        } catch (Exception ex) { System.debug('recovery AI failed: ' + ex.getMessage()); }
        return out;
    }
    private static String assemble(String headline, String pitch, String heroImg, Integer pct, String code, Date expiry) {
        String hero = String.isBlank(heroImg) ? '' :
            '<img src="' + heroImg + '" width="100%" alt="Kwitko Coffee" style="width:100%;max-width:560px;height:auto;border-radius:10px;display:block;margin:0 0 14px"/>';
        return
        '<div style="margin:0;padding:0;background:#f4efe9"><div style="font-family:Georgia,serif;max-width:600px;margin:0 auto;background:#fffdfb;border-radius:14px;overflow:hidden;border:1px solid #ece3d8">' +
        '<div style="background:#6f4e37;padding:22px 28px"><span style="color:#f4efe9;font-size:20px;letter-spacing:1px">☕ Kwitko Coffee Co.</span></div>' +
        '<div style="padding:28px">' +
        '<h1 style="color:#6f4e37;font-size:26px;line-height:1.2;margin:0 0 14px">' + esc(headline) + '</h1>' + hero +
        '<p style="color:#444;font-size:16px;line-height:1.6;margin:0 0 18px">' + esc(pitch) + '</p>' +
        '<div style="background:#f7f1ea;border:1px dashed #c9a87f;border-radius:10px;padding:18px;text-align:center;margin:8px 0 4px">' +
        '<div style="color:#6f4e37;font-size:14px;margin-bottom:6px">Come back and save <strong>' + pct + '% off</strong></div>' +
        '<div style="font-size:26px;font-weight:bold;letter-spacing:2px;color:#3a2a1a">' + esc(code) + '</div>' +
        '<div style="color:#999;font-size:12px;margin-top:6px">Hurry — expires ' + expiry.format() + '</div></div>' +
        '<div style="text-align:center;margin:24px 0 8px"><a href="' + CART + '" style="display:inline-block;background:#6f4e37;color:#fff;font-family:Arial,sans-serif;font-size:16px;font-weight:bold;padding:14px 34px;border-radius:30px;text-decoration:none">Complete my order ➜</a></div>' +
        '</div><div style="background:#faf6f1;padding:16px 28px;color:#b3a695;font-size:12px;font-family:Arial,sans-serif">Roasted fresh in small batches · Kwitko Coffee Co.</div></div></div>';
    }
    private static String esc(String s) { return s == null ? '' : s.escapeHtml4(); }
}
