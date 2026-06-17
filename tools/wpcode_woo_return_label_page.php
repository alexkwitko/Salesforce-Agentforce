<?php
/**
 * Kwitko Woo Return Label Page
 *
 * WPCode: PHP snippet, Active, Run Everywhere. Paste WITHOUT the opening <?php tag.
 *
 * Serves the Salesforce-generated return label URLs:
 *   /return-label/?tracking=KWRET12345678&order=%23506
 *
 * Also exposes a signed Woo endpoint Salesforce calls when a return starts:
 *   POST /wp-json/kwitko/v1/return-label-email
 * This sends the customer-facing label email through Woo/WordPress and writes an order note.
 *
 * Also exposes a signed OTP fallback endpoint for dev/demo orgs that exhaust
 * Salesforce SingleEmail limits:
 *   POST /wp-json/kwitko/v1/verification-code-email
 *
 * This is the Woo-hosted demo/supply-chain label surface. It makes the link that
 * Salesforce sends customer-visible and printable. A production carrier label
 * still needs a carrier API such as UPS/FedEx/Shippo/EasyPost.
 */
if ( ! defined( 'ABSPATH' ) ) { exit; }

if ( ! function_exists( 'kwitko_return_label_hmac_secret' ) ) {
	function kwitko_return_label_hmac_secret() {
		return defined( 'KWITKO_WHK_SECRET' )
			? KWITKO_WHK_SECRET
			: 'kwitko_whk_191b7c0315601372f98523adb3471095a8f1b05bf2bf8936';
	}
}

if ( ! function_exists( 'kwitko_return_label_verify_signature' ) ) {
	function kwitko_return_label_verify_signature( WP_REST_Request $request ) {
		$signature = $request->get_header( 'X-Kwitko-Signature' );
		$secret    = kwitko_return_label_hmac_secret();
		if ( '' === (string) $signature || '' === (string) $secret ) {
			return false;
		}
		$body = $request->get_body();
		$calc = base64_encode( hash_hmac( 'sha256', $body, $secret, true ) );
		return hash_equals( $calc, $signature );
	}
}

if ( ! function_exists( 'kwitko_send_return_label_email' ) ) {
	function kwitko_send_return_label_email( WP_REST_Request $request ) {
		if ( ! kwitko_return_label_verify_signature( $request ) ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'invalid signature' ), 401 );
		}
		if ( ! function_exists( 'WC' ) || ! WC() ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'WooCommerce unavailable' ), 500 );
		}

		$params       = (array) $request->get_json_params();
		$order_id     = isset( $params['order_id'] ) ? absint( $params['order_id'] ) : 0;
		$to_email     = isset( $params['to_email'] ) ? sanitize_email( $params['to_email'] ) : '';
		$order_number = isset( $params['order_number'] ) ? sanitize_text_field( $params['order_number'] ) : '';
		$label_url    = isset( $params['label_url'] ) ? esc_url_raw( $params['label_url'] ) : '';
		$tracking     = isset( $params['tracking'] ) ? sanitize_text_field( $params['tracking'] ) : '';
		$items        = isset( $params['items'] ) ? sanitize_text_field( $params['items'] ) : '';

		$order = $order_id > 0 ? wc_get_order( $order_id ) : false;
		if ( $order && '' === $to_email ) {
			$to_email = $order->get_billing_email();
		}
		if ( $order && '' === $order_number ) {
			$order_number = '#' . $order->get_order_number();
		}
		if ( '' === $to_email || ! is_email( $to_email ) || '' === $label_url || '' === $tracking ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'missing email, label, or tracking' ), 400 );
		}
		if ( '' === $order_number ) {
			$order_number = 'your Kwitko order';
		}

		$subject = 'Your Kwitko Coffee return label - ' . $order_number;
		$message = '<p>Hi,</p>'
			. '<p>Your return for <strong>' . esc_html( $order_number ) . '</strong> is set up.</p>'
			. ( '' === $items ? '' : '<p>Items: ' . esc_html( $items ) . '</p>' )
			. '<p><a href="' . esc_url( $label_url ) . '">Download your prepaid return label</a></p>'
			. '<p>Return tracking: <strong>' . esc_html( $tracking ) . '</strong></p>'
			. '<p>Your refund will be processed after Kwitko receives and checks the merchandise.</p>'
			. '<p>Thanks,<br>Kwitko Coffee Co.</p>';

		$mailer  = WC()->mailer();
		$wrapped = $mailer->wrap_message( $subject, $message );
		$sent    = $mailer->send( $to_email, $subject, $wrapped, array( 'Content-Type: text/html; charset=UTF-8' ) );

		if ( $order ) {
			$order->add_order_note(
				$sent
					? 'Kwitko return label email sent to ' . $to_email . ' (tracking ' . $tracking . ').'
					: 'Kwitko return label email failed for ' . $to_email . ' (tracking ' . $tracking . ').'
			);
		}

		if ( ! $sent ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'Woo mailer failed' ), 500 );
		}
		return new WP_REST_Response( array( 'ok' => true, 'message' => 'return label email sent' ), 200 );
	}
}

if ( ! function_exists( 'kwitko_send_verification_code_email' ) ) {
	function kwitko_send_verification_code_email( WP_REST_Request $request ) {
		if ( ! kwitko_return_label_verify_signature( $request ) ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'invalid signature' ), 401 );
		}

		$params          = (array) $request->get_json_params();
		$to_email        = isset( $params['to_email'] ) ? sanitize_email( $params['to_email'] ) : '';
		$code            = isset( $params['code'] ) ? sanitize_text_field( $params['code'] ) : '';
		$expires_minutes = isset( $params['expires_minutes'] ) ? absint( $params['expires_minutes'] ) : 10;
		if ( '' === $to_email || ! is_email( $to_email ) || ! preg_match( '/^\d{6}$/', $code ) ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'missing email or code' ), 400 );
		}
		if ( $expires_minutes <= 0 ) { $expires_minutes = 10; }

		$subject = 'Your Kwitko Coffee verification code';
		$message = '<p>Hi,</p>'
			. '<p>Your Kwitko Coffee verification code is:</p>'
			. '<p style="font-size:24px;font-weight:bold;letter-spacing:3px">' . esc_html( $code ) . '</p>'
			. '<p>It expires in ' . esc_html( (string) $expires_minutes ) . ' minutes. If you did not request this, ignore this email.</p>';

		if ( function_exists( 'WC' ) && WC() && WC()->mailer() ) {
			$mailer  = WC()->mailer();
			$wrapped = $mailer->wrap_message( $subject, $message );
			$sent    = $mailer->send( $to_email, $subject, $wrapped, array( 'Content-Type: text/html; charset=UTF-8' ) );
		} else {
			$sent = wp_mail( $to_email, $subject, $message, array( 'Content-Type: text/html; charset=UTF-8' ) );
		}

		if ( ! $sent ) {
			return new WP_REST_Response( array( 'ok' => false, 'message' => 'WordPress mailer failed' ), 500 );
		}
		return new WP_REST_Response( array( 'ok' => true, 'message' => 'verification email sent' ), 200 );
	}
}

add_action( 'rest_api_init', function () {
	register_rest_route( 'kwitko/v1', '/return-label-email', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => 'kwitko_send_return_label_email',
	) );
	register_rest_route( 'kwitko/v1', '/verification-code-email', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => 'kwitko_send_verification_code_email',
	) );
} );

add_action( 'template_redirect', function () {
	$path = isset( $_SERVER['REQUEST_URI'] ) ? wp_parse_url( wp_unslash( $_SERVER['REQUEST_URI'] ), PHP_URL_PATH ) : '';
	$path = trim( (string) $path, '/' );
	if ( 'return-label' !== $path ) { return; }

	$tracking = isset( $_GET['tracking'] ) ? sanitize_text_field( wp_unslash( $_GET['tracking'] ) ) : '';
	$order    = isset( $_GET['order'] ) ? sanitize_text_field( wp_unslash( $_GET['order'] ) ) : '';
	if ( '' === $tracking ) {
		status_header( 400 );
		wp_die( esc_html__( 'Missing return tracking number.', 'kwitko' ) );
	}
	if ( '' === $order ) { $order = 'Kwitko order'; }

	status_header( 200 );
	nocache_headers();
	header( 'Content-Type: text/html; charset=' . get_option( 'blog_charset' ) );
	?>
	<!doctype html>
	<html <?php language_attributes(); ?>>
	<head>
		<meta charset="<?php bloginfo( 'charset' ); ?>">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<title><?php echo esc_html( 'Kwitko return label ' . $tracking ); ?></title>
		<style>
			body { margin: 0; font-family: Arial, sans-serif; color: #111; background: #f4f4f1; }
			.page { max-width: 760px; margin: 32px auto; background: #fff; border: 2px solid #111; padding: 28px; }
			.header { display: flex; justify-content: space-between; gap: 20px; border-bottom: 2px solid #111; padding-bottom: 18px; }
			.brand { font-size: 26px; font-weight: 700; letter-spacing: .02em; }
			.badge { border: 1px solid #111; padding: 8px 10px; font-size: 13px; text-transform: uppercase; }
			.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin: 24px 0; }
			.box { border: 1px solid #111; padding: 14px; min-height: 120px; }
			.label { font-size: 12px; font-weight: 700; text-transform: uppercase; margin-bottom: 10px; }
			.big { font-size: 22px; font-weight: 700; }
			.barcode { margin: 28px 0 12px; height: 96px; display: flex; align-items: stretch; gap: 4px; }
			.barcode span { display: block; background: #111; width: var(--w); }
			.tracking { text-align: center; font-size: 24px; font-weight: 700; letter-spacing: .08em; }
			.instructions { border-top: 2px solid #111; padding-top: 18px; line-height: 1.45; }
			.actions { margin: 22px auto 0; text-align: center; }
			button { border: 1px solid #111; background: #111; color: #fff; padding: 10px 16px; font-weight: 700; cursor: pointer; }
			@media print {
				body { background: #fff; }
				.page { margin: 0; border: 2px solid #111; box-shadow: none; }
				.actions { display: none; }
			}
			@media (max-width: 640px) {
				.page { margin: 0; border-left: 0; border-right: 0; }
				.header, .grid { display: block; }
				.box { margin-top: 16px; }
			}
		</style>
	</head>
	<body>
		<main class="page">
			<section class="header">
				<div>
					<div class="brand">Kwitko Coffee Returns</div>
					<div>Prepaid return authorization</div>
				</div>
				<div class="badge">Return Merchandise</div>
			</section>

			<section class="grid">
				<div class="box">
					<div class="label">Ship From</div>
					<div class="big"><?php echo esc_html( $order ); ?></div>
					<div>Customer return</div>
				</div>
				<div class="box">
					<div class="label">Ship To</div>
					<div class="big">Kwitko Coffee Co.</div>
					<div>Returns Department<br>123 Bean Street<br>Austin, TX 78701</div>
				</div>
			</section>

			<div class="barcode" aria-label="<?php echo esc_attr( $tracking ); ?>">
				<span style="--w:10px"></span><span style="--w:4px"></span><span style="--w:18px"></span>
				<span style="--w:6px"></span><span style="--w:12px"></span><span style="--w:5px"></span>
				<span style="--w:22px"></span><span style="--w:4px"></span><span style="--w:14px"></span>
				<span style="--w:7px"></span><span style="--w:18px"></span><span style="--w:5px"></span>
				<span style="--w:10px"></span><span style="--w:22px"></span><span style="--w:6px"></span>
				<span style="--w:12px"></span><span style="--w:4px"></span><span style="--w:18px"></span>
			</div>
			<div class="tracking"><?php echo esc_html( $tracking ); ?></div>

			<section class="instructions">
				<div class="label">Return Instructions</div>
				<ol>
					<li>Pack the item securely with the original packing slip if available.</li>
					<li>Print this page and attach it to the outside of the package.</li>
					<li>Drop the package with the carrier shown in your return email.</li>
					<li>Your refund is processed after Kwitko receives and checks the merchandise.</li>
				</ol>
			</section>
		</main>
		<div class="actions"><button type="button" onclick="window.print()">Print label</button></div>
	</body>
	</html>
	<?php
	exit;
}, 0 );
