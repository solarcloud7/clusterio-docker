// Unit tests for the bridge's pure security helpers.
// Run: node --test bridge/bridge-lib.test.mjs  (no cluster or container needed)
import test from "node:test";
import assert from "node:assert/strict";
import {
	HttpError,
	normalizeRemote, ipToInt, parseCidrs, cidrAllowed,
	authOkHeader, makeRateLimiter,
	commandSizeOk, truncateOutput,
	COMMANDS, commandCatalog, commandFromTemplate,
	MAX_COMMAND_BYTES, MAX_OUTPUT_BYTES,
} from "./bridge-lib.mjs";

test("ipToInt parses dotted quads and rejects everything else", () => {
	assert.equal(ipToInt("0.0.0.0"), 0);
	assert.equal(ipToInt("255.255.255.255"), 0xffffffff);
	assert.equal(ipToInt("172.31.50.10"), (172 << 24 | 31 << 16 | 50 << 8 | 10) >>> 0);
	assert.equal(ipToInt("1.2.3"), null);
	assert.equal(ipToInt("1.2.3.4.5"), null);
	assert.equal(ipToInt("1.2.3.256"), null);
	assert.equal(ipToInt("a.b.c.d"), null);
	assert.equal(ipToInt("1.2.3.-4"), null);
	assert.equal(ipToInt(""), null);
});

test("parseCidrs accepts CIDRs and bare IPs, throws on malformed entries", () => {
	assert.deepEqual(parseCidrs(""), []);
	assert.deepEqual(parseCidrs(" ,  ,"), []);
	const [c] = parseCidrs("172.31.50.0/24");
	assert.equal(c.mask, 0xffffff00);
	assert.equal(c.base, ipToInt("172.31.50.0"));
	// bare IP means /32
	const [single] = parseCidrs("10.0.0.5");
	assert.equal(single.mask, 0xffffffff);
	// /0 is a valid (if permissive) mask
	const [any] = parseCidrs("0.0.0.0/0");
	assert.equal(any.mask, 0);
	assert.equal(any.base, 0);
	// base is masked: a host address given with a network mask normalizes
	const [net] = parseCidrs("172.31.50.99/24");
	assert.equal(net.base, ipToInt("172.31.50.0"));
	// malformed entries are a loud startup error, never silently dropped
	assert.throws(() => parseCidrs("not-an-ip/24"), /Invalid BRIDGE_ALLOWED_CIDRS/);
	assert.throws(() => parseCidrs("10.0.0.0/33"), /Invalid BRIDGE_ALLOWED_CIDRS/);
	assert.throws(() => parseCidrs("10.0.0.0/-1"), /Invalid BRIDGE_ALLOWED_CIDRS/);
	assert.throws(() => parseCidrs("10.0.0.0/abc"), /Invalid BRIDGE_ALLOWED_CIDRS/);
	assert.throws(() => parseCidrs("10.0.0.0/24,garbage"), /Invalid BRIDGE_ALLOWED_CIDRS/);
});

test("cidrAllowed: empty allowlist is deliberately allow-all (fail-open layer)", () => {
	// Pinned behavior: the CIDR check is one layer on top of the dedicated
	// network + bind host + token. Empty list must not lock everyone out.
	assert.equal(cidrAllowed("203.0.113.7", []), true);
});

test("cidrAllowed enforces membership when a list is set", () => {
	const cidrs = parseCidrs("172.31.50.0/24");
	assert.equal(cidrAllowed("172.31.50.1", cidrs), true);
	assert.equal(cidrAllowed("172.31.50.255", cidrs), true);
	assert.equal(cidrAllowed("172.31.51.1", cidrs), false);
	assert.equal(cidrAllowed("10.0.0.1", cidrs), false);
	// non-IPv4 remotes (unmapped IPv6, garbage) are denied, not allowed
	assert.equal(cidrAllowed("::1", cidrs), false);
	assert.equal(cidrAllowed("unknown", cidrs), false);
	// /32 exact match
	const exact = parseCidrs("10.0.0.5");
	assert.equal(cidrAllowed("10.0.0.5", exact), true);
	assert.equal(cidrAllowed("10.0.0.6", exact), false);
	// /0 matches any IPv4
	const any = parseCidrs("0.0.0.0/0");
	assert.equal(cidrAllowed("8.8.8.8", any), true);
});

test("normalizeRemote strips IPv6-mapped prefix and tolerates missing address", () => {
	assert.equal(normalizeRemote("::ffff:172.31.50.10"), "172.31.50.10");
	assert.equal(normalizeRemote("172.31.50.10"), "172.31.50.10");
	assert.equal(normalizeRemote("::1"), "::1");
	assert.equal(normalizeRemote(undefined), "unknown");
});

test("authOkHeader accepts only an exact Bearer token", () => {
	assert.equal(authOkHeader("Bearer s3cret", "s3cret"), true);
	assert.equal(authOkHeader("Bearer wrong", "s3cret"), false);
	assert.equal(authOkHeader("Bearer s3cret ", "s3cret"), false);
	assert.equal(authOkHeader("bearer s3cret", "s3cret"), false);
	assert.equal(authOkHeader("Basic s3cret", "s3cret"), false);
	assert.equal(authOkHeader("", "s3cret"), false);
	assert.equal(authOkHeader(undefined, "s3cret"), false);
});

test("makeRateLimiter blocks after the limit and resets after the window", () => {
	const ok = makeRateLimiter(3, 60_000);
	const t0 = 1_000_000;
	assert.equal(ok("k", t0), true);
	assert.equal(ok("k", t0 + 1), true);
	assert.equal(ok("k", t0 + 2), true);
	assert.equal(ok("k", t0 + 3), false);
	assert.equal(ok("k", t0 + 59_999), false);
	// window rolls over
	assert.equal(ok("k", t0 + 60_000), true);
	// independent keys have independent buckets
	assert.equal(ok("other", t0 + 4), true);
});

test("commandSizeOk enforces the byte cap and string type", () => {
	assert.equal(commandSizeOk("/players online"), true);
	assert.equal(commandSizeOk("x".repeat(MAX_COMMAND_BYTES)), true);
	assert.equal(commandSizeOk("x".repeat(MAX_COMMAND_BYTES + 1)), false);
	// multi-byte characters count in bytes, not chars
	assert.equal(commandSizeOk("é".repeat(MAX_COMMAND_BYTES)), false);
	assert.equal(commandSizeOk(42), false);
	assert.equal(commandSizeOk(null), false);
});

test("truncateOutput caps output bytes and appends the marker", () => {
	assert.equal(truncateOutput("short"), "short");
	assert.equal(truncateOutput(null), "");
	assert.equal(truncateOutput(undefined), "");
	const long = truncateOutput("y".repeat(MAX_OUTPUT_BYTES + 500));
	assert.ok(long.endsWith("...[truncated by clusterio bridge]"));
	assert.ok(Buffer.byteLength(long, "utf8") <= MAX_OUTPUT_BYTES);
});

test("commandFromTemplate builds known templates and rejects the rest", () => {
	assert.equal(commandFromTemplate("players-online", {}), "/players online");
	assert.equal(commandFromTemplate("seed", undefined), "/seed");
	assert.throws(() => commandFromTemplate("no-such-template", {}), (err) => {
		assert.ok(err instanceof HttpError);
		assert.equal(err.status, 404);
		return true;
	});
	// templates take no parameters today; sending any is a client error
	assert.throws(() => commandFromTemplate("seed", { extra: 1 }), (err) => {
		assert.ok(err instanceof HttpError);
		assert.equal(err.status, 400);
		return true;
	});
});

test("every cataloged template builds a command within the size cap", () => {
	assert.equal(commandCatalog().length, COMMANDS.size);
	for (const { id } of commandCatalog()) {
		const command = commandFromTemplate(id, {});
		assert.ok(commandSizeOk(command), `template ${id} exceeds MAX_COMMAND_BYTES`);
	}
});
