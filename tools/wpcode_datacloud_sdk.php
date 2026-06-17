<?php
/**
 * Kwitko Data Cloud / Data 360 Web SDK tracker.
 *
 * INSTALL: WPCode PHP snippet, Auto Insert, Run Everywhere, Active.
 *
 * Before activation, replace $sdk_cdn_script_html with the full Content Delivery Network
 * script tag copied from the Data Cloud Website connector Integration Guide. That script
 * includes the Data 360 module and authenticates events to the selected Website connector.
 */
function kwitko_datacloud_interactions_sdk() {
	if ( is_admin() ) { return; }

	// Paste the complete Data Cloud Website connector CDN <script ...></script> here.
	$sdk_cdn_script_html = '<script defer src="https://cdn.c360a.salesforce.com/beacon/c360a/f60b9bc1-8d47-44de-b802-7e21cf783065/scripts/c360a.min.js"></script>';

	if ( strpos( $sdk_cdn_script_html, 'PASTE_DATA_CLOUD' ) !== false ) {
		echo "\n<!-- Kwitko Data Cloud SDK not configured: paste the Website connector CDN script. -->\n";
		return;
	}

	$known = null;
	if ( is_user_logged_in() ) {
		$u = wp_get_current_user();
		$known = array(
			'id'        => (string) $u->ID,
			'email'     => $u->user_email,
			'firstName' => $u->first_name,
			'lastName'  => $u->last_name,
		);
	}

	$product = null;
	if ( function_exists( 'is_product' ) && is_product() ) {
		global $post;
		$p = wc_get_product( $post->ID );
		if ( $p ) {
			$cats = wp_get_post_terms( $post->ID, 'product_cat', array( 'fields' => 'names' ) );
			$product = array(
				'id'       => (string) $p->get_id(),
				'name'     => $p->get_name(),
				'category' => ( $cats && ! is_wp_error( $cats ) ) ? $cats[0] : '',
				'price'    => (float) $p->get_price(),
				'currency' => get_woocommerce_currency(),
			);
		}
	}

	echo "\n" . $sdk_cdn_script_html . "\n";
	?>
	<script>
	(function () {
		var KNOWN = <?php echo wp_json_encode( $known ); ?>;
		var PRODUCT = <?php echo wp_json_encode( $product ); ?>;
		var COOKIE_DOMAIN = ".hostingersite.com";
		var CONSENT = { purpose: "Tracking", provider: "Kwitko WooCommerce", status: "Opt In" };
		var IDENTITY_KEY = "kwitko_dc_identity";
		var RESET_KEY = "kwitko_dc_reset_requested";
		var BRAND = "Kwitko Coffee";   // brand dimension — same person unifies across brands; this slices by brand

		function waitForSdk(attemptsLeft) {
			if (window.SalesforceInteractions) { return Promise.resolve(window.SalesforceInteractions); }
			if (attemptsLeft <= 0) { return Promise.reject(new Error("SalesforceInteractions SDK not loaded")); }
			return new Promise(function (resolve) { setTimeout(resolve, 100); }).then(function () {
				return waitForSdk(attemptsLeft - 1);
			});
		}

		function cleanText(value, fallback) {
			value = (value || "").toString().trim();
			return value || fallback || "";
		}

		function emailLocalPart(email) {
			return cleanText((email || "").split("@")[0], "Shopper");
		}

		function identityState(email) {
			email = cleanText(email).toLowerCase();
			return email ? "user:" + email : "guest";
		}

		function resetSdkIdentity(si) {
			try {
				window.__kwitkoIdentifyDone = null;
				if (si && typeof si.reset === "function") {
					si.reset();
					return true;
				}
				if (window.SalesforceInteractions && typeof window.SalesforceInteractions.reset === "function") {
					window.SalesforceInteractions.reset();
					return true;
				}
			} catch (e) {}
			return false;
		}

		function syncIdentityState(si, email) {
			try {
				var current = identityState(email);
				var previous = localStorage.getItem(IDENTITY_KEY);
				var resetRequested = localStorage.getItem(RESET_KEY);
				if (resetRequested || (previous && previous !== current)) {
					resetSdkIdentity(si);
					localStorage.removeItem(RESET_KEY);
				}
				localStorage.setItem(IDENTITY_KEY, current);
			} catch (e) {}
		}

		function currentQuantity() {
			var input = document.querySelector("form.cart input.qty, input.qty");
			var qty = input ? parseInt(input.value, 10) : 1;
			return isNaN(qty) || qty < 1 ? 1 : qty;
		}

		function productFromButton(target) {
			var button = target && target.closest ? target.closest("[data-product_id]") : null;
			if (!button || !button.getAttribute("data-product_id")) { return PRODUCT; }
			return {
				id: button.getAttribute("data-product_id"),
				name: button.getAttribute("aria-label") || button.textContent || "Product",
				category: "",
				price: null,
				currency: PRODUCT && PRODUCT.currency ? PRODUCT.currency : "USD"
			};
		}

		function pageCatalogObject() {
			var path = window.location.pathname || "/";
			var id = path === "/" ? "home" : path.replace(/^\/+|\/+$/g, "");
			return {
				id: "page:" + (id || "home"),
				name: cleanText(document.title, id || "Kwitko Coffee"),
				type: "Page"
			};
		}

		function lineItemFor(product) {
			if (!product || !product.id) { return null; }
			var item = {
				catalogObjectType: "Product",
				catalogObjectId: String(product.id),
				quantity: currentQuantity(),
				currency: product.currency || "USD"
			};
			if (product.price !== null && product.price !== undefined && product.price !== "") {
				item.price = Number(product.price);
			}
			return item;
		}

		function identifyWithSdk(si, email, firstName, lastName, userId) {
			email = cleanText(email);
			if (!email || email.indexOf("@") < 1) { return; }
			firstName = cleanText(firstName, emailLocalPart(email));
			lastName = cleanText(lastName, "Customer");
			syncIdentityState(si, email);

			si.sendEvent({
				user: {
					attributes: {
						eventType: "contactPointEmail",
						email: email
					}
				}
			});

			si.sendEvent({
				user: {
					attributes: {
						eventType: "identity",
						firstName: firstName,
						lastName: lastName,
						isAnonymous: "0"
					}
				}
			});

			if (userId) {
				si.sendEvent({
					user: {
						attributes: {
							eventType: "partyIdentification",
							IDName: "WooCommerce User ID",
							IDType: "WooCommerce",
							userId: String(userId)
						}
					}
				});
			}
		}

		waitForSdk(80).then(function (si) {
			syncIdentityState(si, KNOWN && KNOWN.email ? KNOWN.email : "");
			return si.init({
				cookieDomain: COOKIE_DOMAIN,
				consents: [CONSENT]
			}).then(function () {
				var sitemapConfig = {
					global: {
						locale: "en_US",
						listeners: [
							si.listener("change", "#billing_email, input[type='email']", function (event) {
								identifyWithSdk(si, event.target.value, "", "", "");
							}),
							si.listener("click", ".single_add_to_cart_button, .add_to_cart_button", function (event) {
								var item = lineItemFor(productFromButton(event.target));
								if (!item) { return; }
								si.sendEvent({
									interaction: {
										name: si.CartInteractionName.AddToCart,
										lineItem: item
									}
								});
							})
						]
					},
					pageTypes: [
						{
							name: "product_detail",
							isMatch: function () { return !!(PRODUCT && PRODUCT.id); },
							interaction: {
								name: si.CatalogObjectInteractionName.ViewCatalogObjectDetail,
								catalogObject: {
									type: "Product",
									id: function () { return PRODUCT.id; },
									attributes: {
										name: function () { return PRODUCT.name || "Product"; },
										price: function () { return PRODUCT.price; },
										currency: function () { return PRODUCT.currency || "USD"; },
										brand: function () { return BRAND; }
									},
									relatedCatalogObjects: {
										Category: function () { return PRODUCT.category ? [PRODUCT.category] : []; }
									}
									}
								}
							}
						],
						pageTypeDefault: {
							name: "default_page",
							interaction: {
								name: si.CatalogObjectInteractionName.ViewCatalogObject,
								catalogObject: {
									type: function () { return pageCatalogObject().type; },
									id: function () { return pageCatalogObject().id; },
									attributes: {
										name: function () { return pageCatalogObject().name; }
									}
								}
							}
						}
					};

				si.initSitemap(sitemapConfig);

				if (KNOWN && KNOWN.email) {
					identifyWithSdk(si, KNOWN.email, KNOWN.firstName, KNOWN.lastName, KNOWN.id);
				}

				window.kwitkoIdentify = function (email, firstName, lastName) {
					identifyWithSdk(si, email, firstName, lastName, "");
				};

				window.kwitkoDataCloudIdentify = window.kwitkoIdentify;
				window.kwitkoDataCloudReset = function () {
					resetSdkIdentity(si);
					try {
						localStorage.removeItem(RESET_KEY);
						localStorage.setItem(IDENTITY_KEY, "guest");
					} catch (e) {}
				};
			});
		}).catch(function (error) {
			if (window.console && console.warn) {
				console.warn("Kwitko Data Cloud SDK init failed", error);
			}
		});
	})();
	</script>
	<?php
}
add_action( 'wp_head', 'kwitko_datacloud_interactions_sdk', 5 );
