<?php
/**
 * Kwitko engagement tracker → Salesforce Site REST (EngagementRest, route B).
 * Anonymous deviceId cookie captures browsing from visit #1; an identify event (email) fires the
 * moment we know the visitor — logged-in (server-side), checkout email, or chat auth — so Data
 * Cloud / Apex stitch crosses the device + anonymous history to the one person, BEFORE any purchase.
 * INSTALL: WPCode PHP snippet, Auto Insert, Run Everywhere, Active. CORS for this origin is allowlisted.
 */
function kwitko_engagement_tracker() {
	if ( is_admin() ) { return; }
	$endpoint = 'https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/engagement';

	$known = null;
	if ( is_user_logged_in() ) {
		$u = wp_get_current_user();
		$known = array( 'email' => $u->user_email, 'firstName' => $u->first_name, 'lastName' => $u->last_name );
	}
	$product = null;
	if ( function_exists( 'is_product' ) && is_product() ) {
		global $post; $p = wc_get_product( $post->ID );
		if ( $p ) {
			$cats = wp_get_post_terms( $post->ID, 'product_cat', array( 'fields' => 'names' ) );
			$product = array(
				'id'       => (string) $p->get_id(),
				'name'     => $p->get_name(),
				'category' => ( $cats && ! is_wp_error( $cats ) ) ? $cats[0] : '',
				'price'    => (float) $p->get_price(),
			);
		}
	}
	?>
	<script>
	(function () {
		var EP = "<?php echo esc_js( $endpoint ); ?>";
		var KNOWN = <?php echo wp_json_encode( $known ); ?>;
		var PRODUCT = <?php echo wp_json_encode( $product ); ?>;

		function dev() {
			var m = document.cookie.match( /kwitko_dev=([^;]+)/ );
			if ( m ) { return m[1]; }
			var id = 'dev-' + Date.now() + '-' + Math.random().toString( 36 ).slice( 2, 10 );
			document.cookie = 'kwitko_dev=' + id + ';path=/;max-age=31536000;SameSite=Lax';
			return id;
		}
		var DEV = dev();
		var SES = sessionStorage.getItem( 'kwitko_ses' ) || ( 'ses-' + Date.now() );
		sessionStorage.setItem( 'kwitko_ses', SES );

		function send( body ) {
			body.deviceId = DEV; body.sessionId = SES;
			try { fetch( EP, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify( body ) } ); } catch ( e ) {}
		}

		// page view (+ product view) and identify-if-known on every page
		var evs = [ { type: 'pageView', pageUrl: location.pathname } ];
		if ( PRODUCT ) { evs.push( { type: 'catalog', productId: PRODUCT.id, productName: PRODUCT.name, category: PRODUCT.category } ); }
		var body = { events: evs };
		if ( KNOWN && KNOWN.email ) { body.identify = { email: KNOWN.email, firstName: KNOWN.firstName, lastName: KNOWN.lastName }; }
		send( body );

		// dwell time + scroll on exit (gold signal for recommendations)
		var t0 = Date.now(), maxs = 0, sent = false;
		addEventListener( 'scroll', function () {
			var h = document.documentElement, d = ( h.scrollHeight - h.clientHeight ) || 1;
			var p = Math.round( h.scrollTop / d * 100 ); if ( p > maxs ) { maxs = Math.min( 100, p ); }
		}, { passive: true } );
		function dwell() {
			if ( sent ) { return; } var s = Math.round( ( Date.now() - t0 ) / 1000 ); if ( s < 1 ) { return; } sent = true;
			send( { events: [ { type: 'pageEngagement', pageUrl: location.pathname, timeOnPage: s, scrollPct: maxs, productId: PRODUCT ? PRODUCT.id : null, category: PRODUCT ? PRODUCT.category : null } ] } );
		}
		addEventListener( 'visibilitychange', function () { if ( document.visibilityState === 'hidden' ) { dwell(); } } );
		addEventListener( 'pagehide', dwell );

		// identify EARLY — checkout email typed, before buying
		document.addEventListener( 'change', function ( e ) {
			var t = e.target;
			if ( t && ( t.id === 'billing_email' || t.name === 'billing_email' || t.type === 'email' ) && t.value && t.value.indexOf( '@' ) > -1 ) {
				send( { events: [], identify: { email: t.value } } );
			}
		}, true );

		// add-to-cart
		if ( window.jQuery ) { jQuery( document.body ).on( 'added_to_cart', function () { send( { events: [ { type: 'cart', pageUrl: location.pathname } ] } ); } ); }

		// chat-auth hook: chat identity snippet calls window.kwitkoIdentify(email, first, last)
		window.kwitkoIdentify = function ( email, f, l ) { if ( email ) { send( { events: [], identify: { email: email, firstName: f, lastName: l } } ); } };
	})();
	</script>
	<?php
}
add_action( 'wp_footer', 'kwitko_engagement_tracker', 20 );
