<?php
/**
 * Kwitko Agentforce — Web Chat Identity Bridge (CORRECTED, no-JWT path)
 * --------------------------------------------------------------------
 * Paste into a WPCode "PHP Snippet", Auto Insert / Run Everywhere, priority AFTER
 * the chat loader (high number, e.g. 99). DISABLE the old JWT setIdentityToken snippet.
 *
 * WHY THIS WORKS WITHOUT authMode/JWT (the key discovery):
 *   The Service Agent's actions are gated by Apex IdentityService.isVerified(), which only does:
 *       return !isBlank(verifiedEmail) && requestedEmail.equalsIgnoreCase(verifiedEmail);
 *   `verifiedEmail` comes from the agent variable `loggedInEmail`, which the
 *   Kwitko_Web_Chat_V2 MessagingChannel maps from the hidden pre-chat parameter whose
 *   EXTERNAL name is EXACTLY  Kwitko_Logged_In_Email__c.
 *   So passing that one hidden field for a signed-in WP user is sufficient — no
 *   setIdentityToken / JWT / authMode=Auth (which UnAuth deployments reject) required.
 *
 * MUST-DOs for it to take effect:
 *   1. Shopper is logged into WordPress.
 *   2. Hidden fields are set INSIDE onEmbeddedMessagingReady (before the conversation starts),
 *      so the shopper opens a NEW chat after signing in (an open guest chat keeps empty value).
 *   3. We send the exact hidden pre-chat field names accepted by the live
 *      Messaging deployment. The shorter Logged_In_* aliases are rejected by
 *      the bootstrap validator and should not be sent.
 */

if ( is_user_logged_in() ) {
	$u     = wp_get_current_user();
	$email = isset( $u->user_email ) ? $u->user_email : '';
	$first = ! empty( $u->first_name ) ? $u->first_name : ( ! empty( $u->display_name ) ? $u->display_name : '' );

	add_action( 'wp_footer', function () use ( $email, $first ) {
		$email_js = esc_js( $email );
		$first_js = esc_js( $first );
		?>
		<script>
		(function () {
			var KWITKO_EMAIL = "<?php echo $email_js; ?>";
			var KWITKO_FIRST = "<?php echo $first_js; ?>";

			function kwitkoSetIdentity() {
				try {
					if (window.embeddedservice_bootstrap
						&& embeddedservice_bootstrap.prechatAPI
						&& typeof embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields === "function") {
							embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
								"Kwitko_Logged_In_Email__c": KWITKO_EMAIL,
								"Kwitko_Logged_In_First_Name__c": KWITKO_FIRST
							});
							console.log("[Kwitko] hidden identity set:", KWITKO_EMAIL);
					}
					// Also stitch this device's anonymous web-engagement history to the
					// signed-in shopper (the engagement tracker exposes this hook).
					if (typeof window.kwitkoIdentify === "function") {
						window.kwitkoIdentify(KWITKO_EMAIL, KWITKO_FIRST, "");
						console.log("[Kwitko] engagement identify fired for chat identity");
					}
				} catch (e) {
					console.warn("[Kwitko] setHiddenPrechatFields failed", e);
				}
			}

				window.addEventListener("onEmbeddedMessagingReady", kwitkoSetIdentity);
			})();
		</script>
		<?php
	}, 99 );
}
