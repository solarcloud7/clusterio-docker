// Static-cache patch (absorbed from a production consumer — see CHANGELOG 2026-07-05).
//
// The Clusterio controller serves everything under /static with
// `Cache-Control: immutable, max-age=1y` (Controller.js). `immutable` is only safe
// for content-hashed filenames, but plugin webpack builds commonly emit FIXED chunk
// names, and the Module-Federation entry/manifest are fixed by necessity. Result:
// returning browsers pin stale web-UI chunks for a year after every upgrade.
//
// Applied at controller startup (idempotent, re-applies after image pulls) unless
// CONTROLLER_STATIC_CACHE_MODE=immutable. Safe no-op with a log line if the upstream
// pattern is absent (a future core fix degrades cleanly). The real fix belongs in
// Clusterio core (serve non-hashed assets with revalidation) — tracked upstream.
"use strict";
const fs = require("fs");

const candidates = [
	// release target: npm-installed package
	"/clusterio/node_modules/@clusterio/controller/dist/node/src/Controller.js",
	// custom target: vendored monorepo layout
	"/clusterio/packages/controller/dist/node/src/Controller.js",
];
const from = "{ immutable: true, maxAge: 1000 * 86400 * 365 }";
const to = "{ immutable: false, maxAge: 0 }";

let found = false;
for (const target of candidates) {
	let src;
	try {
		src = fs.readFileSync(target, "utf8");
	} catch {
		continue; // layout not present in this image target
	}
	found = true;
	try {
		if (src.includes(to)) {
			console.log(`[static-cache-patch] already applied (${target}) — /static revalidates`);
		} else if (src.includes(from)) {
			fs.writeFileSync(target, src.replace(from, to));
			console.log(`[static-cache-patch] applied (${target}) — /static now revalidates (was immutable 1y)`);
		} else {
			console.log(`[static-cache-patch] pattern not found in ${target} (core changed/fixed upstream?) — skipping, controller starts normally`);
		}
	} catch (err) {
		console.log("[static-cache-patch] non-fatal:", err && err.message);
	}
	break;
}
if (!found) {
	console.log("[static-cache-patch] Controller.js not found in known layouts — skipping");
}
