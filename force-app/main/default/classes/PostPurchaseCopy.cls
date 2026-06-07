// DEPRECATED: superseded by the agent-writes-the-email + EmailService.send_email path.
// Retained as a deterministic fallback only; do not extend. See CHAT-AGENT-ORCHESTRATION-DESIGN (D-9).
/**
 * PostPurchaseCopy — builds a rich, visual offer email.
 * Hybrid: CODE lays out the template (product photo, coupon, CTA — always correct),
 * the AI (Einstein Models API, sfdc_ai__DefaultGPT4OmniMini) writes the exciting
 * headline + "why you'll love it" pitch, grounded in the product's real flavor notes.
 * Always degrades gracefully to deterministic copy so the email never fails to send.
 * The AI call behaves like a callout, so generate() must run BEFORE any DML.
 */
public without sharing class PostPurchaseCopy {

    private static final String MODEL = 'sfdc_ai__DefaultGPT4OmniMini';
    private static final String SHOP = 'https://deepskyblue-deer-920559.hostingersite.com/shop';

    public static String generate(String name, String category,
                                  String product, String productImg, String productDesc,
                                  String compProduct, String compImg,
                                  String code, Decimal pct, Date expiry) {
        Map<String, String> ai = tryAiPieces(name, category, product, productDesc, compProduct);
        String headline = ai.get('headline');
        String pitch    = ai.get('pitch');
        String compLine = ai.get('compLine');
        if (String.isBlank(headline)) headline = 'Brew it again, ' + name + '!';
        if (String.isBlank(pitch))    pitch = String.isNotBlank(productDesc) ? productDesc
                                              : 'A standout in our ' + category + ' lineup — made for your next perfect cup.';
        if (String.isBlank(compLine) && String.isNotBlank(compProduct)) compLine = 'Make it a ritual with ' + compProduct + '.';
        return assemble(name, headline, pitch, product, productImg, compProduct, compImg, compLine, code, pct, expiry);
    }

    /** Asks the AI for {headline, pitch, compLine}. Returns empty map on any problem. */
    private static Map<String, String> tryAiPieces(String name, String category, String product,
                                                   String productDesc, String compProduct) {
        Map<String, String> out = new Map<String, String>();
        if (Test.isRunningTest()) return out;
        try {
            String compAsk = String.isBlank(compProduct) ? ''
                : '"compLine" (one short, tempting line to add ' + compProduct + '), ';
            String prompt =
                'You are a witty, enticing email copywriter for "Kwitko Coffee Co.", a specialty coffee brand. ' +
                'Return ONLY a JSON object (no markdown, no code fences) with keys: ' +
                '"headline" (an exciting line, max 8 words, at most one emoji), ' +
                '"pitch" (exactly 2 punchy, sensory sentences on why ' + product + ' is irresistible, ' +
                'grounded ONLY in these tasting notes: "' + (String.isBlank(productDesc) ? product : productDesc) + '"), ' +
                compAsk +
                'Context: the customer\'s first name is ' + name + '; they love our ' + category + ' coffees. ' +
                'Tone: warm, indulgent, a little playful. Do not invent prices or discounts. JSON only.';

            aiplatform.ModelsAPI m = new aiplatform.ModelsAPI();
            aiplatform.ModelsAPI.createGenerations_Request req = new aiplatform.ModelsAPI.createGenerations_Request();
            req.modelName = MODEL;
            aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
            body.prompt = prompt;
            req.body = body;
            aiplatform.ModelsAPI.createGenerations_Response res = m.createGenerations(req);
            String text = res?.Code200?.generation?.generatedText;
            if (String.isBlank(text)) return out;
            text = text.trim();
            if (text.startsWith('```')) {
                text = text.replaceFirst('(?s)^```[a-zA-Z]*', '');
                if (text.endsWith('```')) text = text.substring(0, text.length() - 3);
            }
            Integer s = text.indexOf('{'), e = text.lastIndexOf('}');
            if (s < 0 || e <= s) return out;
            Map<String, Object> j = (Map<String, Object>) JSON.deserializeUntyped(text.substring(s, e + 1));
            if (j.get('headline') != null) out.put('headline', String.valueOf(j.get('headline')));
            if (j.get('pitch') != null)    out.put('pitch',    String.valueOf(j.get('pitch')));
            if (j.get('compLine') != null) out.put('compLine', String.valueOf(j.get('compLine')));
        } catch (Exception ex) {
            System.debug('AI copy failed, using deterministic fallback: ' + ex.getMessage());
        }
        return out;
    }

    /** Assemble the final HTML email (images + AI words + coupon + CTA). */
    private static String assemble(String name, String headline, String pitch,
                                   String product, String productImg,
                                   String compProduct, String compImg, String compLine,
                                   String code, Decimal pct, Date expiry) {
        String hero = String.isBlank(productImg) ? '' :
            '<img src="' + productImg + '" width="100%" alt="' + esc(product) + '" ' +
            'style="width:100%;max-width:560px;height:auto;border-radius:10px;display:block;margin:0 0 12px"/>';
        String compBlock = String.isBlank(compProduct) ? '' :
            '<table role="presentation" width="100%" style="margin:18px 0;border-top:1px solid #eee;padding-top:14px"><tr>' +
            (String.isBlank(compImg) ? '' :
                '<td width="76" style="vertical-align:top"><img src="' + compImg + '" width="64" height="64" alt="' + esc(compProduct) +
                '" style="width:64px;height:64px;border-radius:8px;object-fit:cover;display:block"/></td>') +
            '<td style="vertical-align:top;padding-left:12px">' +
            '<div style="font-size:12px;letter-spacing:1px;color:#b08968;text-transform:uppercase">Perfect pairing</div>' +
            '<div style="font-weight:bold;color:#3a2a1a">' + esc(compProduct) + '</div>' +
            '<div style="color:#666;font-size:14px">' + esc(compLine) + '</div></td></tr></table>';

        return
        '<div style="margin:0;padding:0;background:#f4efe9">' +
          '<div style="font-family:Georgia,\'Times New Roman\',serif;max-width:600px;margin:0 auto;background:#fffdfb;border-radius:14px;overflow:hidden;border:1px solid #ece3d8">' +
            '<div style="background:#6f4e37;padding:22px 28px"><span style="color:#f4efe9;font-size:20px;letter-spacing:1px">☕ Kwitko Coffee Co.</span></div>' +
            '<div style="padding:28px">' +
              '<h1 style="color:#6f4e37;font-size:26px;line-height:1.2;margin:0 0 6px">' + esc(headline) + '</h1>' +
              '<p style="color:#8a7a6a;margin:0 0 18px;font-size:15px">Hand-picked for you, ' + esc(name) + ' 👋</p>' +
              hero +
              '<h2 style="color:#3a2a1a;font-size:20px;margin:6px 0 6px">' + esc(product) + '</h2>' +
              '<p style="color:#444;font-size:16px;line-height:1.6;margin:0 0 18px">' + esc(pitch) + '</p>' +
              '<div style="background:#f7f1ea;border:1px dashed #c9a87f;border-radius:10px;padding:18px;text-align:center;margin:8px 0 4px">' +
                '<div style="color:#6f4e37;font-size:14px;margin-bottom:6px">Your private treat — <strong>' + pct.intValue() + '% off</strong></div>' +
                '<div style="font-size:26px;font-weight:bold;letter-spacing:2px;color:#3a2a1a">' + esc(code) + '</div>' +
                '<div style="color:#999;font-size:12px;margin-top:6px">One-time use · valid through ' + expiry.format() + '</div>' +
              '</div>' +
              compBlock +
              '<div style="text-align:center;margin:24px 0 8px">' +
                '<a href="' + SHOP + '" style="display:inline-block;background:#6f4e37;color:#fff;font-family:Arial,sans-serif;font-size:16px;font-weight:bold;padding:14px 34px;border-radius:30px;text-decoration:none">Claim ' + pct.intValue() + '% off ➜</a>' +
              '</div>' +
            '</div>' +
            '<div style="background:#faf6f1;padding:16px 28px;color:#b3a695;font-size:12px;font-family:Arial,sans-serif">Roasted fresh in small batches · Kwitko Coffee Co.</div>' +
          '</div>' +
        '</div>';
    }

    private static String esc(String s) { return s == null ? '' : s.escapeHtml4(); }
}
