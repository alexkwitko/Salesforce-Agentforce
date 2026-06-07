# Kwitko In-Chat Login + Zero-Click Cart — install guide

This adds two things to the storefront chat:

1. **In-chat sign-in** — the agent presents a sign-in link/card inside the chat; when clicked, the
   storefront opens a modal that embeds the _real_ WooCommerce `/my-account` login. On success the
   chat session becomes **verified** (JWT) and the agent knows who the shopper is.
2. **Zero-click cart (Option C)** — the agent queues a recommendation and it is added to the shopper's
   live cart automatically (no clicking a URL), with an **A+B redirect-button fallback** if the live add fails.

## Files

| File                                                      | Where it goes                                                                                           |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `keys/kwitko_jwt_private.pem`                             | **Secret.** Into `wp-config.php` as `KWITKO_JWT_PRIVATE_KEY` (never commit, never share).               |
| `keys/kwitko_jwt_public.pem` / `keys/kwitko_jwt_cert.pem` | Upload to Salesforce (User Verification keyset).                                                        |
| `wp_kwitko_inchat_auth.php`                               | WordPress: WPCode **PHP** snippet (Run Everywhere). Prints auth config and loads the controller assets. |
| `kwitko_chat_controller.js`                               | Upload to `wp-content/uploads/kwitko/kwitko_chat_controller.js`.                                        |
| `kwitko_chat_controller.css`                              | Upload to `wp-content/uploads/kwitko/kwitko_chat_controller.css`.                                       |

---

## A. WordPress

1. **Add the private key + config to `wp-config.php`** (above the "stop editing" line). Paste the contents
   of `keys/kwitko_jwt_private.pem` as one string with `\n` line breaks:
   ```php
   define('KWITKO_JWT_PRIVATE_KEY', "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n");
   define('KWITKO_JWT_ISS', 'kwitko-coffee-store');
   define('KWITKO_JWT_KID', 'kwitko-key-1');
   define('KWITKO_WHK_SECRET', 'kwitko_whk_191b7c0315601372f98523adb3471095a8f1b05bf2bf8936'); // for cart queue HMAC
   ```
2. Upload `kwitko_chat_controller.js` and `kwitko_chat_controller.css` to `wp-content/uploads/kwitko/`.
3. Paste `wp_kwitko_inchat_auth.php` as a **PHP** snippet in WPCode → Run Everywhere → Activate.
4. Do not keep an older separate WPCode JavaScript snippet active for `kwitko_chat_controller.js`; it can override
   or drift from the uploaded controller.
5. Do not add a standalone floating "Sign in" button to the page. The visible sign-in affordance belongs inside
   the chat response; the storefront controller only listens for `?kwitko_login=1` / `#kwitko-login` and handles
   identity verification after the shopper signs in.
6. Quick test (logged-in): visit `…/wp-json/kwitko/v1/me` → should show `{logged_in:true,email:…}`,
   and `…/wp-json/kwitko/v1/jwt` → should return a `{jwt:"eyJ…"}`.

> The chat widget cannot script your page (it's a cross-origin iframe), so this controller lives on the
> storefront and talks to the chat through the official `embeddedservice_bootstrap.userVerificationAPI`.

---

## B. Salesforce — User Verification keyset (one time, UI)

Setup → **Messaging Settings** (or "User Verification") → **New** verification:

- **Method:** Authorization (JWT)
- **Issuer:** `kwitko-coffee-store` ← must equal `KWITKO_JWT_ISS`
- **Key ID (kid):** `kwitko-key-1` ← must equal `KWITKO_JWT_KID`
- **Public key:** paste `keys/kwitko_jwt_public.pem` (or upload `kwitko_jwt_cert.pem`)
- **Subject claim:** `sub` → map to the **Messaging End User** identity (email).

Then open the **Embedded Service Deployment** (Kwitko Web Chat) → **User Verification** → select this
verification method → Save & **Publish** the deployment.

### Hidden prechat field (for the cart token)

In the same Embedded Service Deployment → Prechat → add a **Hidden** field bound to
`MessagingSession.Kwitko_Cart_Token__c` (already created in the org). This lets the agent learn the
browser's cart token for zero-click adds.

---

## C. What I wire on the Salesforce/agent side after B is live

- A `My Orders` action that returns order history **only for the cryptographically verified identity**
  (no email input → cannot be spoofed), so a verified shopper can see orders in chat.
- Agent instructions: when the session is verified, greet by name and offer order history in chat;
  when not verified, present the `LoginLinkService` sign-in link/card inside the chat and do not expose
  private account data.
- **Phase 2 cart queue:** an Apex action that POSTs the recommendation to `/wp-json/kwitko/v1/cart`
  (HMAC-signed) keyed by the verified email / cart token, which the controller polls and adds live.

---

## Security notes

- The private key stays in `wp-config.php` only. It is git-ignored here and must never be committed.
- The login modal embeds your genuine `/my-account` page — the shopper types into WooCommerce's own
  form; we never see or store the password.
- The `My Orders` action will read the **verified** identity server-side, so a typed email can never
  unlock another person's data.
