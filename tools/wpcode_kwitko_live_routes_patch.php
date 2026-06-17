<?php
/**
 * Kwitko Live Woo Routes Patch
 *
 * WPCode: PHP snippet, Active, Run Everywhere.
 * Paste WITHOUT the opening <?php tag when using WPCode.
 *
 * Purpose: one live-site patch for the routes currently missing/stale on Woo:
 * - GET    /wp-json/kwitko/v1/me
 * - GET    /wp-json/kwitko/v1/jwt
 * - GET    /wp-json/kwitko/v1/cart
 * - POST   /wp-json/kwitko/v1/cart
 * - DELETE /wp-json/kwitko/v1/cart
 * - GET    /wp-json/kwitko/v1/identify
 * - POST   /wp-json/kwitko/v1/identify
 * - DELETE /wp-json/kwitko/v1/identify
 * - POST   /wp-json/kwitko/v1/verification-code-email
 * - POST   /wp-json/kwitko/v1/return-label-email
 * - POST   /wp-json/kwitko/v1/service-interaction
 * - POST   /wp-json/kwitko/v1/service-interactions/pull
 * - POST   /wp-json/kwitko/v1/service-interactions/ack
 * - GET    /return-label/?tracking=...&order=...
 * - URL    ?kc_add=PRODUCT_IDS&kc_clear=1&kc_coupon=CODE
 * - Woo admin order action: "Kwitko: mark return received"
 *
 * Production note: define KWITKO_WHK_SECRET and JWT constants in wp-config.php.
 */

if ( ! defined( 'ABSPATH' ) ) { exit; }

if ( ! defined( 'KWITKO_LIVE_ROUTES_PATCH_VERSION' ) ) {
	define( 'KWITKO_LIVE_ROUTES_PATCH_VERSION', '20260615.13' );
}

if ( ! function_exists( 'kwitko_live_sf_user_verification_enabled' ) ) {
	function kwitko_live_sf_user_verification_enabled() {
		return defined( 'KWITKO_SF_USER_VERIFICATION_ENABLED' ) && KWITKO_SF_USER_VERIFICATION_ENABLED;
	}
}

if ( ! function_exists( 'kwitko_live_defer_salesforce_script_tags' ) ) {
	function kwitko_live_defer_salesforce_script_tags( $html ) {
		return preg_replace_callback( '/<script\b(?=[^>]*\bsrc=[\'"][^\'"]*(?:c360a\.salesforce\.com|embeddedservice|ESWKwitkoWebChat)[^\'"]*[\'"])([^>]*)>/i', function ( $matches ) {
			$attrs = $matches[1];
			if ( preg_match( '/\b(?:async|defer)\b/i', $attrs ) ) {
				return $matches[0];
			}
			return '<script defer' . $attrs . '>';
		}, $html );
	}
}

add_action( 'template_redirect', function () {
	if ( is_admin() || wp_doing_ajax() || wp_is_json_request() ) { return; }
	ob_start( 'kwitko_live_defer_salesforce_script_tags' );
}, -999 );

if ( ! function_exists( 'kwitko_live_secret' ) ) {
	function kwitko_live_secret() {
		return defined( 'KWITKO_WHK_SECRET' )
			? KWITKO_WHK_SECRET
			: 'kwitko_whk_191b7c0315601372f98523adb3471095a8f1b05bf2bf8936';
	}
}

if ( ! function_exists( 'kwitko_live_verify_signature' ) ) {
	function kwitko_live_verify_signature( WP_REST_Request $request, $header_name = 'X-Kwitko-Signature' ) {
		$signature = $request->get_header( $header_name );
		$secret    = kwitko_live_secret();
		if ( '' === (string) $signature || '' === (string) $secret ) { return false; }
		$calc = base64_encode( hash_hmac( 'sha256', $request->get_body(), $secret, true ) );
		return hash_equals( $calc, (string) $signature );
	}
}

if ( ! function_exists( 'kwitko_live_no_cache_response' ) ) {
	function kwitko_live_no_cache_response( $data ) {
		nocache_headers();
		$response = new WP_REST_Response( $data );
		$response->header( 'Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0' );
		$response->header( 'Pragma', 'no-cache' );
		$response->header( 'Expires', '0' );
		return $response;
	}
}

if ( ! function_exists( 'kwitko_live_service_category' ) ) {
	function kwitko_live_service_category( $message ) {
		$m = strtolower( (string) $message );
		if ( preg_match( '/\b(return|exchange|return label|label)\b/', $m ) ) { return 'Returns'; }
		if ( preg_match( '/\b(refund|refunds|refunded)\b/', $m ) ) { return 'Refund'; }
		if ( preg_match( '/\b(track|tracking|ship|shipping|shipment|deliver|delivery|ups|fedex|usps)\b/', $m ) ) { return 'Shipping'; }
		if ( preg_match( '/\b(pay|payment|billing|card|failed payment|invoice)\b/', $m ) ) { return 'Billing'; }
		if ( preg_match( '/\b(login|log in|sign in|account|password|email address|address change)\b/', $m ) ) { return 'Account'; }
		if ( preg_match( '/\b(case|ticket|human|agent|complaint|support)\b/', $m ) ) { return 'Escalation'; }
		if ( preg_match( '/\b(order|orders|cancel|cancellation|last order)\b/', $m ) ) { return 'Order'; }
		return '';
	}
}

if ( ! function_exists( 'kwitko_live_service_logs' ) ) {
	function kwitko_live_service_logs() {
		$logs = get_option( 'kwitko_service_interaction_logs', array() );
		return is_array( $logs ) ? $logs : array();
	}
}

if ( ! function_exists( 'kwitko_live_save_service_logs' ) ) {
	function kwitko_live_save_service_logs( $logs ) {
		$logs = is_array( $logs ) ? array_values( $logs ) : array();
		if ( count( $logs ) > 300 ) { $logs = array_slice( $logs, -300 ); }
		if ( false === get_option( 'kwitko_service_interaction_logs', false ) ) {
			add_option( 'kwitko_service_interaction_logs', $logs, '', false );
		} else {
			update_option( 'kwitko_service_interaction_logs', $logs, false );
		}
	}
}

if ( ! function_exists( 'kwitko_live_clean_chat_message' ) ) {
	function kwitko_live_clean_chat_message( $message ) {
		$message = wp_strip_all_tags( (string) $message );
		$message = preg_replace( '/\b(otp|verification code|one-time(?: email)? code|code)\s*[:#=]?\s*\(?\d{6}\)?/i', '$1 [redacted]', $message );
		$message = preg_replace( '/\b\d{6}\b/', '[redacted]', $message );
		$message = trim( $message );
		return function_exists( 'mb_substr' ) ? mb_substr( $message, 0, 1000 ) : substr( $message, 0, 1000 );
	}
}

if ( ! function_exists( 'kwitko_live_mail_transport_error' ) ) {
	function kwitko_live_mail_transport_error() {
		$settings = false;
		if ( function_exists( 'fluentMailGetSettings' ) ) {
			$settings = fluentMailGetSettings( array(), false );
		} else {
			$settings = get_option( 'fluentmail-settings', false );
		}
		if ( is_array( $settings ) && array_key_exists( 'connections', $settings ) ) {
			$connections = $settings['connections'];
			if ( is_array( $connections ) && ! empty( $connections ) ) { return ''; }
			return 'FluentSMTP has no delivery connection configured.';
		}
		if ( function_exists( 'fluentMailGetSettings' ) ) {
			return 'FluentSMTP has no delivery connection configured.';
		}
		return '';
	}
}

if ( ! function_exists( 'kwitko_live_b64url' ) ) {
	function kwitko_live_b64url( $data ) {
		return rtrim( strtr( base64_encode( $data ), '+/', '-_' ), '=' );
	}
}

if ( ! function_exists( 'kwitko_live_mint_jwt' ) ) {
	function kwitko_live_mint_jwt( $email, $first_name = '' ) {
		if ( ! defined( 'KWITKO_JWT_PRIVATE_KEY' ) ) {
			return new WP_Error( 'no_key', 'JWT key not configured', array( 'status' => 500 ) );
		}
		$iss = defined( 'KWITKO_JWT_ISS' ) ? KWITKO_JWT_ISS : 'kwitko-coffee-store';
		$kid = defined( 'KWITKO_JWT_KID' ) ? KWITKO_JWT_KID : 'kwitko-key-1';
		$now = time();
		$header = array( 'alg' => 'RS256', 'typ' => 'JWT', 'kid' => $kid );
		$payload = array(
			'sub'        => strtolower( $email ),
			'iss'        => $iss,
			'iat'        => $now,
			'exp'        => $now + 3600,
			'email'      => strtolower( $email ),
			'first_name' => $first_name,
		);
		$signing_input = kwitko_live_b64url( wp_json_encode( $header ) ) . '.' . kwitko_live_b64url( wp_json_encode( $payload ) );
		$sig = '';
		if ( ! openssl_sign( $signing_input, $sig, KWITKO_JWT_PRIVATE_KEY, OPENSSL_ALGO_SHA256 ) ) {
			return new WP_Error( 'sign_failed', 'Could not sign JWT', array( 'status' => 500 ) );
		}
		return $signing_input . '.' . kwitko_live_b64url( $sig );
	}
}

add_action( 'rest_api_init', function () {
	register_rest_route( 'kwitko/v1', '/me', array(
		'methods'             => 'GET',
		'permission_callback' => '__return_true',
		'callback'            => function () {
			if ( is_user_logged_in() ) {
				$u = wp_get_current_user();
				return kwitko_live_no_cache_response( array(
					'logged_in'      => true,
					'email'          => $u->user_email,
					'first_name'     => $u->first_name ? $u->first_name : $u->display_name,
					'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION,
				) );
			}
			return kwitko_live_no_cache_response( array( 'logged_in' => false, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION ) );
		},
	), true );

	register_rest_route( 'kwitko/v1', '/jwt', array(
		'methods'             => 'GET',
		'permission_callback' => '__return_true',
		'callback'            => function () {
			if ( ! is_user_logged_in() ) {
				return new WP_Error( 'not_logged_in', 'Sign in first.', array( 'status' => 401 ) );
			}
			$u = wp_get_current_user();
			$first_name = $u->first_name ? $u->first_name : $u->display_name;
			$jwt = kwitko_live_mint_jwt( $u->user_email, $first_name );
			if ( is_wp_error( $jwt ) ) { return $jwt; }
			return array(
				'jwt'            => $jwt,
				'email'          => $u->user_email,
				'first_name'     => $first_name,
				'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION,
			);
		},
	), true );

	register_rest_route( 'kwitko/v1', '/cart', array(
		array(
			'methods'             => 'GET',
			'permission_callback' => '__return_true',
			'callback'            => function ( WP_REST_Request $request ) {
				$token = sanitize_text_field( $request->get_param( 'token' ) );
				if ( '' === $token ) { return array( 'items' => array(), 'coupon' => '', 'clear' => false ); }
				$data = get_transient( 'kwitko_cart_' . $token );
				return $data ? $data : array( 'items' => array(), 'coupon' => '', 'clear' => false );
			},
		),
		array(
			'methods'             => 'POST',
			'permission_callback' => '__return_true',
			'callback'            => function ( WP_REST_Request $request ) {
				if ( ! kwitko_live_verify_signature( $request ) ) {
					return new WP_Error( 'bad_sig', 'Invalid signature', array( 'status' => 401 ) );
				}
				$body = (array) json_decode( $request->get_body(), true );
				$token = isset( $body['token'] ) ? sanitize_text_field( $body['token'] ) : '';
				if ( '' === $token ) { return new WP_Error( 'no_token', 'token required', array( 'status' => 400 ) ); }
				$payload = array(
					'items'  => isset( $body['items'] ) ? array_values( array_map( 'intval', (array) $body['items'] ) ) : array(),
					'coupon' => isset( $body['coupon'] ) ? sanitize_text_field( $body['coupon'] ) : '',
					'clear'  => ! empty( $body['clear'] ),
				);
				set_transient( 'kwitko_cart_' . $token, $payload, 15 * MINUTE_IN_SECONDS );
				return array( 'ok' => true, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
			},
		),
		array(
			'methods'             => 'DELETE',
			'permission_callback' => '__return_true',
			'callback'            => function ( WP_REST_Request $request ) {
				$token = sanitize_text_field( $request->get_param( 'token' ) );
				if ( '' !== $token ) { delete_transient( 'kwitko_cart_' . $token ); }
				return array( 'ok' => true, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
			},
		),
	), true );

	register_rest_route( 'kwitko/v1', '/identify', array(
		array(
			'methods'             => 'GET',
			'permission_callback' => '__return_true',
			'callback'            => function ( WP_REST_Request $request ) {
				$token = sanitize_text_field( $request->get_param( 'token' ) );
				if ( '' === $token ) { return array( 'email' => '', 'firstName' => '' ); }
				$data = get_transient( 'kwitko_identify_' . $token );
				return $data ? $data : array( 'email' => '', 'firstName' => '' );
			},
		),
		array(
			'methods'             => 'POST',
			'permission_callback' => '__return_true',
			'callback'            => function ( WP_REST_Request $request ) {
				if ( ! kwitko_live_verify_signature( $request ) ) {
					return new WP_Error( 'bad_sig', 'Invalid signature', array( 'status' => 401 ) );
				}
				$body = (array) json_decode( $request->get_body(), true );
				$token = isset( $body['token'] ) ? sanitize_text_field( $body['token'] ) : '';
				$email = isset( $body['email'] ) ? sanitize_email( $body['email'] ) : '';
				if ( '' === $token || '' === $email ) {
					return new WP_Error( 'missing', 'token and email required', array( 'status' => 400 ) );
				}
				set_transient( 'kwitko_identify_' . $token, array(
					'email'     => $email,
					'firstName' => isset( $body['firstName'] ) ? sanitize_text_field( $body['firstName'] ) : '',
				), 30 * MINUTE_IN_SECONDS );
				return array( 'ok' => true, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
			},
		),
		array(
			'methods'             => 'DELETE',
			'permission_callback' => '__return_true',
			'callback'            => function ( WP_REST_Request $request ) {
				$token = sanitize_text_field( $request->get_param( 'token' ) );
				if ( '' !== $token ) { delete_transient( 'kwitko_identify_' . $token ); }
				return array( 'ok' => true, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
			},
		),
	), true );

	register_rest_route( 'kwitko/v1', '/verification-code-email', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => function ( WP_REST_Request $request ) {
			if ( ! kwitko_live_verify_signature( $request ) ) {
				return new WP_Error( 'bad_sig', 'Invalid signature', array( 'status' => 401 ) );
			}
			$params = (array) $request->get_json_params();
			$to_email = isset( $params['to_email'] ) ? sanitize_email( $params['to_email'] ) : '';
			$code = isset( $params['code'] ) ? sanitize_text_field( $params['code'] ) : '';
			$expires = isset( $params['expires_minutes'] ) ? absint( $params['expires_minutes'] ) : 10;
			if ( '' === $to_email || ! is_email( $to_email ) || ! preg_match( '/^\d{6}$/', $code ) ) {
				return new WP_Error( 'missing', 'email and 6-digit code required', array( 'status' => 400 ) );
			}
			$mail_error = kwitko_live_mail_transport_error();
			if ( '' !== $mail_error ) {
				return new WP_Error( 'mail_not_configured', $mail_error, array( 'status' => 503 ) );
			}
			if ( $expires <= 0 ) { $expires = 10; }
			$subject = 'Your Kwitko Coffee verification code';
			$message = '<p>Hi,</p><p>Your Kwitko Coffee verification code is:</p>'
				. '<p style="font-size:24px;font-weight:bold;letter-spacing:3px">' . esc_html( $code ) . '</p>'
				. '<p>It expires in ' . esc_html( (string) $expires ) . ' minutes. If you did not request this, ignore this email.</p>';
			if ( function_exists( 'WC' ) && WC() && WC()->mailer() ) {
				$mailer = WC()->mailer();
				$sent = $mailer->send( $to_email, $subject, $mailer->wrap_message( $subject, $message ), array( 'Content-Type: text/html; charset=UTF-8' ) );
			} else {
				$sent = wp_mail( $to_email, $subject, $message, array( 'Content-Type: text/html; charset=UTF-8' ) );
			}
			if ( ! $sent ) { return new WP_Error( 'mail_failed', 'WordPress mailer failed', array( 'status' => 500 ) ); }
			return array( 'ok' => true, 'message' => 'verification email sent', 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
		},
	), true );

	register_rest_route( 'kwitko/v1', '/return-label-email', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => function ( WP_REST_Request $request ) {
			if ( ! kwitko_live_verify_signature( $request ) ) {
				return new WP_Error( 'bad_sig', 'Invalid signature', array( 'status' => 401 ) );
			}
			if ( ! function_exists( 'WC' ) || ! WC() ) {
				return new WP_Error( 'woo_unavailable', 'WooCommerce unavailable', array( 'status' => 500 ) );
			}
			$params = (array) $request->get_json_params();
			$order_id = isset( $params['order_id'] ) ? absint( $params['order_id'] ) : 0;
			$to_email = isset( $params['to_email'] ) ? sanitize_email( $params['to_email'] ) : '';
			$order_number = isset( $params['order_number'] ) ? sanitize_text_field( $params['order_number'] ) : '';
			$label_url = isset( $params['label_url'] ) ? esc_url_raw( $params['label_url'] ) : '';
			$tracking = isset( $params['tracking'] ) ? sanitize_text_field( $params['tracking'] ) : '';
			$items = isset( $params['items'] ) ? sanitize_text_field( $params['items'] ) : '';
			$order = $order_id > 0 ? wc_get_order( $order_id ) : false;
			if ( $order && '' === $to_email ) { $to_email = $order->get_billing_email(); }
			if ( $order && '' === $order_number ) { $order_number = '#' . $order->get_order_number(); }
			if ( '' === $to_email || ! is_email( $to_email ) || '' === $label_url || '' === $tracking ) {
				return new WP_Error( 'missing', 'missing email, label, or tracking', array( 'status' => 400 ) );
			}
			$mail_error = kwitko_live_mail_transport_error();
			if ( '' !== $mail_error ) {
				if ( $order ) { $order->add_order_note( 'Kwitko return label email blocked: ' . $mail_error ); }
				return new WP_Error( 'mail_not_configured', $mail_error, array( 'status' => 503 ) );
			}
			if ( '' === $order_number ) { $order_number = 'your Kwitko order'; }
			$subject = 'Your Kwitko Coffee return label - ' . $order_number;
			$message = '<p>Hi,</p><p>Your return for <strong>' . esc_html( $order_number ) . '</strong> is set up.</p>'
				. ( '' === $items ? '' : '<p>Items: ' . esc_html( $items ) . '</p>' )
				. '<p><a href="' . esc_url( $label_url ) . '">Download your prepaid return label</a></p>'
				. '<p>Return tracking: <strong>' . esc_html( $tracking ) . '</strong></p>'
				. '<p>Your refund will be processed after Kwitko receives and checks the merchandise.</p>'
				. '<p>Thanks,<br>Kwitko Coffee Co.</p>';
			$mailer = WC()->mailer();
			$sent = $mailer->send( $to_email, $subject, $mailer->wrap_message( $subject, $message ), array( 'Content-Type: text/html; charset=UTF-8' ) );
			if ( $order ) {
				$order->add_order_note( $sent
					? 'Kwitko return label email sent to ' . $to_email . ' (tracking ' . $tracking . ').'
					: 'Kwitko return label email failed for ' . $to_email . ' (tracking ' . $tracking . ').' );
			}
			if ( ! $sent ) { return new WP_Error( 'mail_failed', 'Woo mailer failed', array( 'status' => 500 ) ); }
			return array( 'ok' => true, 'message' => 'return label email sent', 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
		},
	), true );

	register_rest_route( 'kwitko/v1', '/service-interaction', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => function ( WP_REST_Request $request ) {
			$params = (array) $request->get_json_params();
			$message = isset( $params['message'] ) ? kwitko_live_clean_chat_message( $params['message'] ) : '';
			$category = isset( $params['category'] ) ? sanitize_text_field( $params['category'] ) : '';
			if ( '' === $category ) { $category = kwitko_live_service_category( $message ); }
			if ( '' === $message || '' === $category ) {
				return array( 'ok' => true, 'ignored' => true, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
			}

			$email = isset( $params['email'] ) ? sanitize_email( $params['email'] ) : '';
			if ( '' === $email && is_user_logged_in() ) {
				$u = wp_get_current_user();
				$email = $u ? sanitize_email( $u->user_email ) : '';
			}
			$conversation_id = isset( $params['conversationId'] ) ? sanitize_text_field( $params['conversationId'] ) : '';
			$token = isset( $params['token'] ) ? sanitize_text_field( $params['token'] ) : '';
			$page = isset( $params['page'] ) ? esc_url_raw( $params['page'] ) : '';
			$logged_in = ! empty( $params['loggedIn'] ) || is_user_logged_in();
			$hash_bucket = (string) floor( time() / 30 );
			$fingerprint = hash( 'sha256', strtolower( $token . '|' . $conversation_id . '|' . $message . '|' . $hash_bucket ) );

			$logs = kwitko_live_service_logs();
			foreach ( $logs as $existing ) {
				if ( is_array( $existing ) && isset( $existing['fingerprint'] ) && hash_equals( (string) $existing['fingerprint'], $fingerprint ) ) {
					return array(
						'ok'             => true,
						'duplicate'      => true,
						'id'             => isset( $existing['id'] ) ? $existing['id'] : '',
						'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION,
					);
				}
			}

			$id = 'ksi_' . gmdate( 'YmdHis' ) . '_' . substr( wp_hash( $fingerprint . microtime( true ) ), 0, 10 );
			$logs[] = array(
				'id'             => $id,
				'fingerprint'    => $fingerprint,
				'category'       => $category,
				'message'        => $message,
				'email'          => $email,
				'loggedIn'       => $logged_in,
				'conversationId' => $conversation_id,
				'token'          => $token,
				'page'           => $page,
				'userAgent'      => isset( $_SERVER['HTTP_USER_AGENT'] ) ? sanitize_text_field( wp_unslash( $_SERVER['HTTP_USER_AGENT'] ) ) : '',
				'createdAt'      => gmdate( 'c' ),
				'exportedAt'     => '',
			);
			kwitko_live_save_service_logs( $logs );
			return array( 'ok' => true, 'id' => $id, 'category' => $category, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
		},
	), true );

	register_rest_route( 'kwitko/v1', '/service-interactions/pull', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => function ( WP_REST_Request $request ) {
			if ( ! kwitko_live_verify_signature( $request ) ) {
				return new WP_Error( 'bad_sig', 'Invalid signature', array( 'status' => 401 ) );
			}
			$params = (array) $request->get_json_params();
			$limit = isset( $params['limit'] ) ? max( 1, min( 100, absint( $params['limit'] ) ) ) : 50;
			$records = array();
			foreach ( kwitko_live_service_logs() as $entry ) {
				if ( ! is_array( $entry ) || ! empty( $entry['exportedAt'] ) ) { continue; }
				unset( $entry['fingerprint'] );
				$records[] = $entry;
				if ( count( $records ) >= $limit ) { break; }
			}
			return array( 'ok' => true, 'records' => $records, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
		},
	), true );

	register_rest_route( 'kwitko/v1', '/service-interactions/ack', array(
		'methods'             => 'POST',
		'permission_callback' => '__return_true',
		'callback'            => function ( WP_REST_Request $request ) {
			if ( ! kwitko_live_verify_signature( $request ) ) {
				return new WP_Error( 'bad_sig', 'Invalid signature', array( 'status' => 401 ) );
			}
			$params = (array) $request->get_json_params();
			$ids = isset( $params['ids'] ) ? array_map( 'sanitize_text_field', (array) $params['ids'] ) : array();
			$id_map = array_fill_keys( $ids, true );
			$acked = 0;
			$logs = kwitko_live_service_logs();
			foreach ( $logs as &$entry ) {
				if ( is_array( $entry ) && isset( $entry['id'] ) && isset( $id_map[ $entry['id'] ] ) && empty( $entry['exportedAt'] ) ) {
					$entry['exportedAt'] = gmdate( 'c' );
					$acked++;
				}
			}
			unset( $entry );
			kwitko_live_save_service_logs( $logs );
			return array( 'ok' => true, 'acked' => $acked, 'bridge_version' => KWITKO_LIVE_ROUTES_PATCH_VERSION );
		},
	), true );
} );

if ( ! function_exists( 'kwitko_live_cart_link_ids' ) ) {
	function kwitko_live_cart_link_ids( $raw ) {
		$ids = array();
		foreach ( explode( ',', (string) $raw ) as $part ) {
			$id = absint( trim( $part ) );
			if ( $id > 0 ) { $ids[] = $id; }
			if ( count( $ids ) >= 10 ) { break; }
		}
		return $ids;
	}
}

add_action( 'template_redirect', function () {
	if ( is_admin() || wp_doing_ajax() || wp_is_json_request() || empty( $_GET['kc_add'] ) || ! function_exists( 'WC' ) ) { return; }
	if ( function_exists( 'wc_load_cart' ) ) { wc_load_cart(); }
	if ( ! WC() || ! WC()->cart ) { return; }
	$ids = kwitko_live_cart_link_ids( wp_unslash( $_GET['kc_add'] ) );
	if ( empty( $ids ) ) { return; }
	$clear = ! empty( $_GET['kc_clear'] ) && in_array( strtolower( sanitize_text_field( wp_unslash( $_GET['kc_clear'] ) ) ), array( '1', 'true', 'yes', 'replace' ), true );
	if ( $clear ) { WC()->cart->empty_cart(); }
	$added = 0;
	foreach ( $ids as $product_id ) {
		if ( WC()->cart->add_to_cart( $product_id, 1 ) ) { $added++; }
	}
	if ( ! empty( $_GET['kc_coupon'] ) ) {
		$coupon = wc_format_coupon_code( sanitize_text_field( wp_unslash( $_GET['kc_coupon'] ) ) );
		if ( $coupon && ! WC()->cart->has_discount( $coupon ) ) { WC()->cart->apply_coupon( $coupon ); }
	}
	if ( $added > 0 && function_exists( 'wc_add_notice' ) ) {
		wc_add_notice( $clear ? __( 'Your recommendation was added to a fresh cart.', 'kwitko' ) : __( 'Your recommendation was added to your cart.', 'kwitko' ), 'success' );
	}
	wp_safe_redirect( function_exists( 'wc_get_cart_url' ) ? wc_get_cart_url() : home_url( '/cart-2/' ) );
	exit;
}, 0 );

add_action( 'wp_footer', function () {
	if ( is_admin() ) { return; }
	$current_user = is_user_logged_in() ? wp_get_current_user() : null;
	$first_name = $current_user ? ( $current_user->first_name ? $current_user->first_name : $current_user->display_name ) : '';
	?>
	<script id="kwitko-live-identity-hardening">
	(function () {
	  "use strict";
	  var VERSION = "<?php echo esc_js( KWITKO_LIVE_ROUTES_PATCH_VERSION ); ?>";
	  window.KWITKO_AUTH = Object.assign({}, window.KWITKO_AUTH || {}, {
	    meUrl: "<?php echo esc_url_raw( rest_url( 'kwitko/v1/me' ) ); ?>",
	    jwtUrl: "<?php echo esc_url_raw( rest_url( 'kwitko/v1/jwt' ) ); ?>",
	    identifyUrl: "<?php echo esc_url_raw( rest_url( 'kwitko/v1/identify' ) ); ?>",
	    serviceInteractionUrl: "<?php echo esc_url_raw( rest_url( 'kwitko/v1/service-interaction' ) ); ?>",
	    loginUrl: "<?php echo esc_url_raw( home_url( '/my-account-2/' ) ); ?>",
	    nonce: "<?php echo esc_attr( wp_create_nonce( 'wp_rest' ) ); ?>",
	    loggedIn: <?php echo $current_user ? 'true' : 'false'; ?>,
	    email: "<?php echo $current_user ? esc_js( $current_user->user_email ) : ''; ?>",
	    firstName: "<?php echo esc_js( $first_name ); ?>",
	    serverLoggedIn: <?php echo $current_user ? 'true' : 'false'; ?>,
	    serverEmail: "<?php echo $current_user ? esc_js( $current_user->user_email ) : ''; ?>",
	    serverFirstName: "<?php echo esc_js( $first_name ); ?>",
	    jwtUserVerification: <?php echo kwitko_live_sf_user_verification_enabled() ? 'true' : 'false'; ?>,
	    controllerVersion: VERSION,
	    liveRoutesVersion: VERSION
	  });
	  window.KWITKO_CHAT_AUTH_BRIDGE_VERSION = VERSION;
	  window.KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION = VERSION;
	  if (window.KWITKO_LIVE_IDENTITY_HARDENING_VERSION === VERSION) return;
	  window.KWITKO_LIVE_IDENTITY_HARDENING_VERSION = VERSION;
	  var authReady = false;
	  var messagingReady = false;
	  var prechatAttempted = false;

	  function setChatAuthPending(pending) {
	    try {
	      var id = "kwitko-chat-auth-pending-css";
	      if (!document.getElementById(id)) {
	        var css = document.createElement("style");
	        css.id = id;
	        css.textContent =
	          "html.kwitko-chat-auth-pending iframe#embeddedMessagingFrame," +
	          "html.kwitko-chat-auth-pending iframe.embeddedMessagingFrame," +
	          "html.kwitko-chat-auth-pending .embeddedMessagingFrame," +
	          "html.kwitko-chat-auth-pending [id^='embeddedMessaging']{" +
	          "opacity:0!important;pointer-events:none!important;visibility:hidden!important" +
	          "}";
	        document.head.appendChild(css);
	      }
	      document.documentElement.classList.toggle("kwitko-chat-auth-pending", !!pending);
	    } catch (e) {}
	  }

	  setChatAuthPending(true);

	  function releaseChatWhenIdentityReady() {
	    try {
	      var a = auth();
	      if (!authReady) return;
	      if (a.loggedIn && a.email && !prechatAttempted) return;
	      setChatAuthPending(false);
	    } catch (e) {
	      setChatAuthPending(false);
	    }
	  }

	  setTimeout(function () {
	    if (!authReady) authReady = true;
	    if (auth().loggedIn && auth().email && !prechatAttempted) {
	      try { console.warn("[Kwitko chat] Releasing chat after identity gate timeout"); } catch (e) {}
	      prechatAttempted = true;
	    }
	    releaseChatWhenIdentityReady();
	  }, 12000);

	  function auth() {
	    return window.KWITKO_AUTH || {};
	  }

	  function serverRenderedUser() {
	    var a = auth();
	    return !!(a.serverLoggedIn && a.serverEmail);
	  }

	  function restoreServerRenderedUser() {
	    var a = auth();
	    window.KWITKO_AUTH = Object.assign({}, a, {
	      loggedIn: true,
	      email: a.serverEmail || a.email || "",
	      firstName: a.serverFirstName || a.firstName || ""
	    });
	    syncAuthState("user:" + String(window.KWITKO_AUTH.email || "").toLowerCase());
	    ensureFreshConversationForIdentity();
	    setHiddenPrechatFields();
	    sendIdentityToken();
	  }

	  function token() {
	    try {
	      var t = localStorage.getItem("kwitko_token");
	      if (!t) {
	        t = "kc-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
	        localStorage.setItem("kwitko_token", t);
	      }
	      return t;
	    } catch (e) {
	      return "";
	    }
	  }

	  function cacheBust(url) {
	    try {
	      var u = new URL(url, location.href);
	      u.searchParams.set("_kwitko_nocache", Date.now().toString(36));
	      return u.toString();
	    } catch (e) {
	      return url + (url.indexOf("?") === -1 ? "?" : "&") + "_kwitko_nocache=" + Date.now().toString(36);
	    }
	  }

	  function fetchJSON(url) {
	    return fetch(cacheBust(url), {
	      credentials: "include",
	      cache: "no-store",
	      headers: { "X-WP-Nonce": auth().nonce || "" }
	    }).then(function (r) { return r.ok ? r.json() : null; });
	  }

	  function serviceCategory(message) {
	    var m = String(message || "").toLowerCase();
	    if (/\b(return|exchange|return label|label)\b/.test(m)) return "Returns";
	    if (/\b(refund|refunds|refunded)\b/.test(m)) return "Refund";
	    if (/\b(track|tracking|ship|shipping|shipment|deliver|delivery|ups|fedex|usps)\b/.test(m)) return "Shipping";
	    if (/\b(pay|payment|billing|card|failed payment|invoice)\b/.test(m)) return "Billing";
	    if (/\b(login|log in|sign in|account|password|email address|address change)\b/.test(m)) return "Account";
	    if (/\b(case|ticket|human|agent|complaint|support)\b/.test(m)) return "Escalation";
	    if (/\b(order|orders|cancel|cancellation|last order)\b/.test(m)) return "Order";
	    return "";
	  }

	  function textFromPayload(value, depth) {
	    if (depth > 5 || value == null) return "";
	    if (typeof value === "string") {
	      var s = value.trim();
	      if (!s) return "";
	      if ((s[0] === "{" && s[s.length - 1] === "}") || (s[0] === "[" && s[s.length - 1] === "]")) {
	        try {
	          return textFromPayload(JSON.parse(s), depth + 1);
	        } catch (e) {}
	      }
	      return s;
	    }
	    if (Array.isArray(value)) {
	      for (var i = 0; i < value.length; i += 1) {
	        var arrText = textFromPayload(value[i], depth + 1);
	        if (arrText) return arrText;
	      }
	      return "";
	    }
	    if (typeof value === "object") {
	      var preferred = ["text", "message", "value", "label", "title"];
	      for (var p = 0; p < preferred.length; p += 1) {
	        var key = preferred[p];
	        if (typeof value[key] === "string" && value[key].trim()) return value[key].trim();
	      }
	      var keys = Object.keys(value);
	      for (var k = 0; k < keys.length; k += 1) {
	        var found = textFromPayload(value[keys[k]], depth + 1);
	        if (found) return found;
	      }
	    }
	    return "";
	  }

	  function conversationIdFromEvent(event) {
	    var d = (event && event.detail) || {};
	    return d.conversationId || d.conversationID || d.id || "";
	  }

	  function isEndUserMessage(event) {
	    var d = (event && event.detail) || {};
	    var entry = d.conversationEntry || (d.data && d.data.conversationEntry) || d;
	    var sender = entry.sender || {};
	    var role = String(sender.role || entry.senderRole || "").toLowerCase();
	    var display = String(entry.senderDisplayName || "").toLowerCase();
	    return /end\s*user|enduser|customer|client|guest/.test(role) || display === "guest";
	  }

	  function messageFromEvent(event) {
	    var d = (event && event.detail) || {};
	    var entry = d.conversationEntry || (d.data && d.data.conversationEntry) || d;
	    return textFromPayload(entry.entryPayload || entry.message || entry.text || d.message || d.text || "", 0);
	  }

	  function logServiceInteraction(message, category) {
	    var a = auth();
	    if (!a.serviceInteractionUrl || !message || !category) return;
	    var conversationId = "";
	    try { conversationId = sessionStorage.getItem("kwitko_conversation_id") || ""; } catch (e) {}
	    var t = token();
	    var dedupe = category + "|" + conversationId + "|" + t + "|" + String(message).toLowerCase().slice(0, 200);
	    try {
	      var last = sessionStorage.getItem("kwitko_last_service_log");
	      if (last === dedupe) return;
	      sessionStorage.setItem("kwitko_last_service_log", dedupe);
	    } catch (e) {}
	    fetch(a.serviceInteractionUrl, {
	      method: "POST",
	      credentials: "include",
	      cache: "no-store",
	      headers: {
	        "Content-Type": "application/json",
	        "X-WP-Nonce": a.nonce || ""
	      },
	      body: JSON.stringify({
	        message: message,
	        category: category,
	        conversationId: conversationId,
	        token: t,
	        email: a.email || "",
	        loggedIn: !!(a.loggedIn && a.email),
	        page: location.href
	      })
	    }).catch(function () {});
	  }

	  function resetDataCloudIdentity() {
	    try { window.__kwitkoIdentifyDone = null; } catch (e) {}
	    try {
	      if (typeof window.kwitkoDataCloudReset === "function") {
	        window.kwitkoDataCloudReset();
	      } else if (window.SalesforceInteractions && typeof window.SalesforceInteractions.reset === "function") {
	        window.SalesforceInteractions.reset();
	        localStorage.setItem("kwitko_dc_identity", "guest");
	        localStorage.removeItem("kwitko_dc_reset_requested");
	      } else {
	        localStorage.setItem("kwitko_dc_reset_requested", String(Date.now()));
	      }
	    } catch (e) {}
	  }

	  function clearSalesforceBrowserStorage(reason) {
	    try {
	      var orgId = "00DXX0000000000";
	      ["localStorage", "sessionStorage"].forEach(function (storeName) {
	        var store = window[storeName];
	        if (!store) return;
	        var keys = [];
	        for (var i = 0; i < store.length; i += 1) {
	          var key = store.key(i);
	          if (key === orgId + "_WEB_STORAGE" || /embedded(service|messaging)|salesforce|scrt|ESW/i.test(key || "")) {
	            keys.push(key);
	          }
	        }
	        keys.forEach(function (key) { try { store.removeItem(key); } catch (e) {} });
	      });
	      if (window.console && console.warn) {
	        console.warn("[Kwitko chat] Cleared stale Salesforce chat storage:", reason || "identity change");
	      }
	    } catch (e) {}
	  }

	  function clearSalesforceChatSession(reason) {
	    clearSalesforceBrowserStorage(reason);
	    if (!auth().jwtUserVerification) return;
	    try {
	      var api = window.embeddedservice_bootstrap && embeddedservice_bootstrap.userVerificationAPI;
	      if (api && typeof api.clearSession === "function") {
	        api.clearSession({ shouldEndSession: true });
	      }
	    } catch (e) {}
	  }

	  function resetOnLogout() {
	    try { localStorage.removeItem("kwitko_token"); } catch (e) {}
	    resetDataCloudIdentity();
	    clearSalesforceChatSession("logout");
	  }

	  function currentIdentity() {
	    var a = auth();
	    return a.loggedIn && a.email ? "user:" + String(a.email).toLowerCase() : "guest";
	  }

	  function ensureFreshConversationForIdentity() {
	    try {
	      var current = currentIdentity();
	      var previous = localStorage.getItem("kwitko_chat_identity");
	      if (previous !== null && previous !== current) {
	        if (current === "guest") {
	          resetOnLogout();
	        } else {
	          clearSalesforceChatSession("login identity changed");
	        }
	      }
	      localStorage.setItem("kwitko_chat_identity", current);
	    } catch (e) {}
	  }

	  function resetLoggedInStaleGuestConversationOnce() {
	    try {
	      var id = currentIdentity();
	      if (id === "guest") return;
	      var key = "kwitko_verified_reset_" + VERSION;
	      if (sessionStorage.getItem(key) === id) return;
	      clearSalesforceChatSession("logged-in stale guest reset");
	      sessionStorage.setItem(key, id);
	      setTimeout(sendIdentityToken, 250);
	      setTimeout(setHiddenPrechatFields, 300);
	    } catch (e) {}
	  }

	  function fireDataCloudIdentify(email, firstName, lastName) {
	    var identifyFn = typeof window.kwitkoDataCloudIdentify === "function"
	      ? window.kwitkoDataCloudIdentify
	      : (typeof window.kwitkoIdentify === "function" ? window.kwitkoIdentify : null);
	    if (!email || !identifyFn) return false;
	    if (window.__kwitkoIdentifyDone === email) return true;
	    try {
	      identifyFn(email, firstName || "", lastName || "");
	      window.__kwitkoIdentifyDone = email;
	      return true;
	    } catch (e) {
	      return false;
	    }
	  }

	  function setHiddenPrechatFields() {
	    var a = auth();
	    if (!a.loggedIn || !a.email) return;
	    fireDataCloudIdentify(a.email, a.firstName || "", "");
	    try {
	      if (!messagingReady) return;
	      if (!window.embeddedservice_bootstrap || !embeddedservice_bootstrap.prechatAPI) return;
	      embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
	        "Kwitko_Logged_In_Email__c": a.email,
	        "Kwitko_Logged_In_First_Name__c": a.firstName || ""
	      });
	      prechatAttempted = true;
	      var cartToken = token();
	      if (cartToken) {
	        embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
	          "Kwitko_Cart_Token__c": cartToken
	        });
	      }
	      releaseChatWhenIdentityReady();
	    } catch (e) {}
	  }

	  function sendIdentityToken() {
	    var a = auth();
	    if (!a.jwtUserVerification || !a.loggedIn || !a.email || !a.jwtUrl) return;
	    fetchJSON(a.jwtUrl).then(function (res) {
	      try {
	        if (
	          res && res.jwt &&
	          window.embeddedservice_bootstrap &&
	          embeddedservice_bootstrap.userVerificationAPI &&
	          typeof embeddedservice_bootstrap.userVerificationAPI.setIdentityToken === "function"
	        ) {
	          embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({
	            identityTokenType: "JWT",
	            identityToken: res.jwt
	          });
	        }
	      } catch (e) {}
	    }).catch(function () {});
	  }

	  function syncAuthState(state) {
	    try {
	      var previous = localStorage.getItem("kwitko_chat_auth_state");
	      if (previous !== null && previous !== state) {
	        if (state === "guest") {
	          resetOnLogout();
	        } else {
	          clearSalesforceChatSession("login auth state changed");
	        }
	      }
	      localStorage.setItem("kwitko_chat_auth_state", state);
	    } catch (e) {}
	  }

	  function refreshMe() {
	    var a = auth();
	    if (!a.meUrl) {
	      authReady = true;
	      releaseChatWhenIdentityReady();
	      return Promise.resolve();
	    }
	    return fetchJSON(a.meUrl).then(function (me) {
	      var wasLoggedIn = !!(a.loggedIn && a.email);
	      if (me && me.logged_in) {
	        window.KWITKO_AUTH = Object.assign({}, auth(), {
	          loggedIn: true,
	          email: me.email || a.email || "",
	          firstName: me.first_name || a.firstName || ""
	        });
	        syncAuthState("user:" + String(window.KWITKO_AUTH.email || "").toLowerCase());
	        ensureFreshConversationForIdentity();
	        setHiddenPrechatFields();
	        sendIdentityToken();
	      } else if (me) {
	        if (wasLoggedIn && serverRenderedUser()) {
	          try { console.warn("[Kwitko chat] Ignored stale /me guest response while page rendered logged in"); } catch (e) {}
	          restoreServerRenderedUser();
	          return;
	        }
	        if (wasLoggedIn) resetOnLogout();
	        window.KWITKO_AUTH = Object.assign({}, auth(), {
	          loggedIn: false,
	          email: "",
	          firstName: ""
	        });
	        syncAuthState("guest");
	        ensureFreshConversationForIdentity();
	      }
	      authReady = true;
	      releaseChatWhenIdentityReady();
	    }).catch(function () {
	      authReady = true;
	      releaseChatWhenIdentityReady();
	    });
	  }

	  window.addEventListener("onEmbeddedMessagingReady", function () {
	    messagingReady = true;
	    ensureFreshConversationForIdentity();
	    resetLoggedInStaleGuestConversationOnce();
	    setHiddenPrechatFields();
	    sendIdentityToken();
	    [0, 250, 1000, 3000, 6000].forEach(function (delay) {
	      setTimeout(function () {
	        setHiddenPrechatFields();
	        refreshMe();
	      }, delay);
	    });
	  });
	  window.addEventListener("onEmbeddedMessagingConversationStarted", function (event) {
	    try {
	      var id = conversationIdFromEvent(event);
	      if (id) sessionStorage.setItem("kwitko_conversation_id", id);
	    } catch (e) {}
	  });
	  window.addEventListener("onEmbeddedMessageSent", function (event) {
	    try {
	      if (!isEndUserMessage(event)) return;
	      var message = messageFromEvent(event);
	      var category = serviceCategory(message);
	      if (!category) return;
	      logServiceInteraction(message, category);
	    } catch (e) {}
	  });
	  window.addEventListener("onEmbeddedMessagingIdentityTokenExpired", sendIdentityToken);

	  ensureFreshConversationForIdentity();
	  refreshMe();
	  setInterval(pollIdentify, 5000);
	  setInterval(refreshMe, 30000);

	  function pollIdentify() {
	    var a = auth();
	    var t = token();
	    if (!t || !a.identifyUrl) return;
	    fetchJSON(a.identifyUrl + "?token=" + encodeURIComponent(t)).then(function (q) {
	      if (!q || !q.email) return;
	      fireDataCloudIdentify(q.email, q.firstName || "", "");
	      fetch(a.identifyUrl + "?token=" + encodeURIComponent(t), {
	        method: "DELETE",
	        credentials: "include",
	        headers: { "X-WP-Nonce": a.nonce || "" }
	      }).catch(function () {});
	    }).catch(function () {});
	  }
	})();
	</script>
	<script id="kwitko-live-routes-cart-poller">
	(function () {
	  "use strict";
	  var VERSION = "<?php echo esc_js( KWITKO_LIVE_ROUTES_PATCH_VERSION ); ?>";
	  window.KWITKO_AUTH = Object.assign({}, window.KWITKO_AUTH || {}, {
	    cartUrl: "<?php echo esc_url_raw( rest_url( 'kwitko/v1/cart' ) ); ?>",
	    loginUrl: "<?php echo esc_url_raw( home_url( '/my-account-2/' ) ); ?>",
	    storeApi: "<?php echo esc_url_raw( rest_url( 'wc/store/v1' ) ); ?>",
	    liveRoutesVersion: VERSION
	  });
	  if (window.KWITKO_CART_POLLER_VERSION) return;
	  window.KWITKO_CART_POLLER_VERSION = VERSION;

	  function token() {
	    try {
	      var t = localStorage.getItem("kwitko_token");
	      if (!t) {
	        t = "kc-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
	        localStorage.setItem("kwitko_token", t);
	      }
	      return t;
	    } catch (e) {
	      return "";
	    }
	  }

	  function auth() {
	    return window.KWITKO_AUTH || {};
	  }

	  function fetchJSON(url, opts) {
	    return fetch(url, opts || {}).then(function (r) { return r.ok ? r.json() : null; });
	  }

	  function storeNonce() {
	    var a = auth();
	    if (!a.storeApi) return Promise.resolve("");
	    return fetch(a.storeApi + "/cart", { credentials: "include" })
	      .then(function (r) { return r.headers.get("Nonce") || r.headers.get("X-WC-Store-API-Nonce") || ""; })
	      .catch(function () { return ""; });
	  }

	  function refreshMiniCart() {
	    try {
	      if (window.wp && wp.data && wp.data.dispatch) {
	        wp.data.dispatch("wc/store/cart").invalidateResolutionForStore();
	      }
	    } catch (e) {}
	    try {
	      if (window.jQuery) jQuery(document.body).trigger("wc_fragment_refresh");
	    } catch (e) {}
	    try {
	      document.body.dispatchEvent(new CustomEvent("wc-blocks_render_blocks_frontend"));
	      document.body.dispatchEvent(new CustomEvent("kwitko-cart-updated"));
	    } catch (e) {}
	  }

	  function ensureLoginStyles() {
	    if (document.getElementById("kwitko-login-overlay-css")) return;
	    var css = document.createElement("style");
	    css.id = "kwitko-login-overlay-css";
	    css.textContent =
	      "#kwitko-login-overlay{position:fixed;inset:0;z-index:2147483000;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center}" +
	      "#kwitko-login-modal{width:min(460px,92vw);height:min(680px,90vh);background:#fff;border-radius:12px;overflow:hidden;display:flex;flex-direction:column;box-shadow:0 20px 60px rgba(0,0,0,.35)}" +
	      "#kwitko-login-head{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;background:#3a2a1a;color:#fff;font:600 15px/1 system-ui,Arial,sans-serif}" +
	      "#kwitko-login-close{background:transparent;border:0;color:#fff;font-size:24px;line-height:1;cursor:pointer}" +
	      "#kwitko-login-frame{border:0;width:100%;height:100%;flex:1}";
	    document.head.appendChild(css);
	  }

	  function stripLoginQuery() {
	    try {
	      var url = new URL(location.href);
	      if (url.searchParams.has("kwitko_login")) {
	        url.searchParams.delete("kwitko_login");
	        history.replaceState(null, "", url.pathname + url.search + url.hash);
	      }
	    } catch (e) {}
	  }

	  function openLoginFallback() {
	    if (document.getElementById("kwitko-login-overlay")) return;
	    var a = auth();
	    var loginUrl = a.loginUrl || "/my-account-2/";
	    ensureLoginStyles();
	    var overlay = document.createElement("div");
	    overlay.id = "kwitko-login-overlay";
	    overlay.innerHTML =
	      '<div id="kwitko-login-modal" role="dialog" aria-modal="true" aria-label="Sign in">' +
	      '<div id="kwitko-login-head"><span>Sign in to Kwitko Coffee</span>' +
	      '<button id="kwitko-login-close" type="button" aria-label="Close">&times;</button></div>' +
	      '<iframe id="kwitko-login-frame" src="' + loginUrl + '" title="Sign in"></iframe>' +
	      "</div>";
	    document.body.appendChild(overlay);
	    document.getElementById("kwitko-login-close").onclick = function () {
	      overlay.remove();
	      stripLoginQuery();
	    };
	    overlay.addEventListener("click", function (e) {
	      if (e.target === overlay) {
	        overlay.remove();
	        stripLoginQuery();
	      }
	    });
	  }

	  function maybeOpenLoginFallback() {
	    try {
	      var q = new URLSearchParams(location.search);
	      if (q.get("kwitko_login") !== "1" && location.hash !== "#kwitko-login") return;
	      if (typeof window.kwitkoOpenLogin === "function") {
	        try { window.kwitkoOpenLogin(); } catch (e) {}
	      }
	      setTimeout(function () {
	        if (!document.getElementById("kwitko-login-overlay")) openLoginFallback();
	      }, 250);
	    } catch (e) {}
	  }

	  function addItemsLive(items, coupon) {
	    var a = auth();
	    if (!a.storeApi) return Promise.resolve(false);
	    return storeNonce().then(function (nonce) {
	      if (!nonce) return false;
	      var chain = Promise.resolve(true);
	      (items || []).forEach(function (id) {
	        chain = chain.then(function (ok) {
	          if (!ok) return false;
	          return fetch(a.storeApi + "/cart/add-item", {
	            method: "POST",
	            credentials: "include",
	            headers: { "Content-Type": "application/json", "Nonce": nonce },
	            body: JSON.stringify({ id: parseInt(id, 10), quantity: 1 })
	          }).then(function (r) { return r.ok; }).catch(function () { return false; });
	        });
	      });
	      return chain.then(function (ok) {
	        if (!ok || !coupon) return ok;
	        return fetch(a.storeApi + "/cart/apply-coupon", {
	          method: "POST",
	          credentials: "include",
	          headers: { "Content-Type": "application/json", "Nonce": nonce },
	          body: JSON.stringify({ code: coupon })
	        }).then(function () { return true; }).catch(function () { return true; });
	      });
	    });
	  }

	  function pollCart() {
	    var a = auth();
	    var t = token();
	    if (!a.cartUrl || !t) return;
	    fetchJSON(a.cartUrl + "?token=" + encodeURIComponent(t), { credentials: "include" })
	      .then(function (q) {
	        if (!q || !q.items || !q.items.length) return;
	        var replaceCart = q.clear === true || q.clear === "true" || q.clear === 1 || q.clear === "1";
	        addItemsLive(q.items, q.coupon || "").then(function (ok) {
	          fetch(a.cartUrl + "?token=" + encodeURIComponent(t), { method: "DELETE", credentials: "include" }).catch(function () {});
	          if (ok) {
	            refreshMiniCart();
	            return;
	          }
	          var url = location.origin + "/?kc_add=" + q.items.join(",")
	            + (replaceCart ? "&kc_clear=1" : "")
	            + (q.coupon ? "&kc_coupon=" + encodeURIComponent(q.coupon) : "");
	          location.assign(url);
	        });
	      })
	      .catch(function () {});
	  }

	  setInterval(pollCart, 3000);
	  pollCart();
	  setTimeout(maybeOpenLoginFallback, 0);
	  setTimeout(maybeOpenLoginFallback, 1200);
	  if (document.readyState === "loading") {
	    document.addEventListener("DOMContentLoaded", maybeOpenLoginFallback);
	  }
	})();
	</script>
	<?php
}, 7 );

add_action( 'template_redirect', function () {
	$path = isset( $_SERVER['REQUEST_URI'] ) ? wp_parse_url( wp_unslash( $_SERVER['REQUEST_URI'] ), PHP_URL_PATH ) : '';
	if ( 'return-label' !== trim( (string) $path, '/' ) ) { return; }
	$tracking = isset( $_GET['tracking'] ) ? sanitize_text_field( wp_unslash( $_GET['tracking'] ) ) : '';
	$order = isset( $_GET['order'] ) ? sanitize_text_field( wp_unslash( $_GET['order'] ) ) : 'Kwitko order';
	if ( '' === $tracking ) {
		status_header( 400 );
		wp_die( esc_html__( 'Missing return tracking number.', 'kwitko' ) );
	}
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
			@media print { body { background: #fff; } .page { margin: 0; border: 2px solid #111; } .actions { display: none; } }
			@media (max-width: 640px) { .page { margin: 0; border-left: 0; border-right: 0; } .header, .grid { display: block; } .box { margin-top: 16px; } }
		</style>
	</head>
	<body>
		<main class="page">
			<section class="header">
				<div><div class="brand">Kwitko Coffee Returns</div><div>Prepaid return authorization</div></div>
				<div class="badge">Return Merchandise</div>
			</section>
			<section class="grid">
				<div class="box"><div class="label">Ship From</div><div class="big"><?php echo esc_html( $order ); ?></div><div>Customer return</div></div>
				<div class="box"><div class="label">Ship To</div><div class="big">Kwitko Coffee Co.</div><div>Returns Department<br>123 Bean Street<br>Austin, TX 78701</div></div>
			</section>
			<div class="barcode" aria-label="<?php echo esc_attr( $tracking ); ?>">
				<span style="--w:10px"></span><span style="--w:4px"></span><span style="--w:18px"></span><span style="--w:6px"></span><span style="--w:12px"></span><span style="--w:5px"></span><span style="--w:22px"></span><span style="--w:4px"></span><span style="--w:14px"></span><span style="--w:7px"></span><span style="--w:18px"></span><span style="--w:5px"></span><span style="--w:10px"></span><span style="--w:22px"></span><span style="--w:6px"></span><span style="--w:12px"></span><span style="--w:4px"></span><span style="--w:18px"></span>
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

add_filter( 'woocommerce_order_actions', function ( $actions ) {
	$actions['kwitko_mark_return_received'] = __( 'Kwitko: mark return received', 'kwitko' );
	return $actions;
} );

add_action( 'woocommerce_order_action_kwitko_mark_return_received', function ( $order ) {
	if ( ! ( $order instanceof WC_Order ) ) { return; }
	$user = wp_get_current_user();
	$payload = array(
		'order_id'      => (string) $order->get_id(),
		'order_number'  => (string) $order->get_order_number(),
		'received_note' => 'Woo admin marked returned merchandise received for order #' . $order->get_order_number(),
		'received_by'   => $user && $user->exists() ? $user->user_email : 'woocommerce-admin',
		'source'        => 'woocommerce_admin_order_action',
	);
	$body = wp_json_encode( $payload );
	$sig = base64_encode( hash_hmac( 'sha256', $body, kwitko_live_secret(), true ) );
	$resp = wp_remote_post( 'https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/woo/return-receipt/', array(
		'headers'  => array( 'Content-Type' => 'application/json', 'X-Kwitko-Signature' => $sig ),
		'body'     => $body,
		'timeout'  => 60,
		'blocking' => true,
	) );
	if ( is_wp_error( $resp ) ) {
		$order->add_order_note( 'Kwitko return receipt sync failed: ' . $resp->get_error_message() );
		return;
	}
	$code = (int) wp_remote_retrieve_response_code( $resp );
	$text = wp_remote_retrieve_body( $resp );
	$data = json_decode( $text, true );
	if ( $code >= 200 && $code < 300 && is_array( $data ) && ! empty( $data['ok'] ) ) {
		$order->update_meta_data( '_kwitko_return_received_synced_at', gmdate( 'c' ) );
		if ( ! empty( $data['wooRefundId'] ) ) { $order->update_meta_data( '_kwitko_sf_woo_refund_id', sanitize_text_field( $data['wooRefundId'] ) ); }
		if ( ! empty( $data['returnOrderNumber'] ) ) { $order->update_meta_data( '_kwitko_sf_return_order_number', sanitize_text_field( $data['returnOrderNumber'] ) ); }
		$order->save();
		$order->add_order_note( 'Kwitko return receipt synced to Salesforce. ' . ( ! empty( $data['message'] ) ? $data['message'] : '' ) );
	} else {
		$order->add_order_note( 'Kwitko return receipt sync failed (' . $code . '): ' . $text );
	}
} );
