// Pure helpers for the Clusterio bridge — no env reads, no @clusterio/lib import,
// so `node --test bridge/bridge-lib.test.mjs` runs without a cluster or container.
import crypto from "node:crypto";

export const MAX_COMMAND_BYTES = 4096;
export const MAX_OUTPUT_BYTES = 1800;

export class HttpError extends Error {
	constructor(status, message, logMessage = message) {
		super(message);
		this.status = status;
		this.logMessage = logMessage;
	}
}

export function fail(status, message) {
	throw new HttpError(status, message);
}

export function normalizeRemote(remoteAddress) {
	if (!remoteAddress) { return "unknown"; }
	if (remoteAddress.startsWith("::ffff:")) { return remoteAddress.slice(7); }
	return remoteAddress;
}

export function ipToInt(ip) {
	const parts = ip.split(".");
	if (parts.length !== 4) { return null; }
	let out = 0;
	for (const part of parts) {
		if (!/^\d{1,3}$/.test(part)) { return null; }
		const n = Number(part);
		if (n < 0 || n > 255) { return null; }
		out = (out << 8) + n;
	}
	return out >>> 0;
}

export function parseCidrs(raw) {
	return raw.split(",").map((s) => s.trim()).filter(Boolean).map((entry) => {
		const [ip, bitsRaw] = entry.includes("/") ? entry.split("/", 2) : [entry, "32"];
		const bits = Number(bitsRaw);
		const base = ipToInt(ip);
		if (base === null || !Number.isInteger(bits) || bits < 0 || bits > 32) {
			throw new Error(`Invalid BRIDGE_ALLOWED_CIDRS entry: ${entry}`);
		}
		const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
		// >>> 0 keeps the base unsigned — plain `base & mask` goes negative for
		// networks with the high bit set (first octet >= 128) and then never
		// matches cidrAllowed's unsigned comparison.
		return { entry, base: (base & mask) >>> 0, mask };
	});
}

// Empty allowlist = allow all: the CIDR check is one layer on top of the
// dedicated network, the bind host, and the bearer token. Pinned by tests —
// do not flip this to deny-all without revisiting docs/discord-bridge.md.
export function cidrAllowed(remoteIp, allowedCidrs) {
	if (allowedCidrs.length === 0) { return true; }
	const ip = ipToInt(remoteIp);
	if (ip === null) { return false; }
	return allowedCidrs.some(({ base, mask }) => ((ip & mask) >>> 0) === base);
}

export function tokenDigest(value) {
	return crypto.createHash("sha256").update(value).digest();
}

export function authOkHeader(header, token) {
	if (typeof header !== "string" || !header.startsWith("Bearer ")) { return false; }
	return crypto.timingSafeEqual(tokenDigest(header.slice(7)), tokenDigest(token));
}

export function makeRateLimiter(limitPerWindow, windowMs) {
	const buckets = new Map();
	return function rateLimitOk(key, now = Date.now()) {
		const bucket = buckets.get(key);
		if (!bucket || now >= bucket.resetAt) {
			buckets.set(key, { count: 1, resetAt: now + windowMs });
			return true;
		}
		if (bucket.count >= limitPerWindow) { return false; }
		bucket.count += 1;
		return true;
	};
}

export function commandSizeOk(command) {
	return typeof command === "string" && Buffer.byteLength(command, "utf8") <= MAX_COMMAND_BYTES;
}

export function truncateOutput(output) {
	const text = String(output ?? "");
	const bytes = Buffer.from(text, "utf8");
	if (bytes.length <= MAX_OUTPUT_BYTES) { return text; }
	const marker = "\n...[truncated by clusterio bridge]";
	const markerBytes = Buffer.byteLength(marker, "utf8");
	return bytes.subarray(0, Math.max(0, MAX_OUTPUT_BYTES - markerBytes)).toString("utf8") + marker;
}

export const COMMANDS = new Map([
	["players-online", {
		description: "List online players",
		params: {},
		build: () => "/players online",
	}],
	["seed", {
		description: "Show the map seed",
		params: {},
		build: () => "/seed",
	}],
	["time", {
		description: "Show server time",
		params: {},
		build: () => "/time",
	}],
	["evolution", {
		description: "Show enemy evolution",
		params: {},
		build: () => "/evolution",
	}],
	["list-surfaces", {
		description: "List Factorio surfaces",
		params: {},
		build: () => "/list-surfaces",
	}],
	["surface-export-list-platforms", {
		description: "List Space Age platforms through the surface_export plugin",
		params: {},
		build: () => "/sc rcon.print(remote.call('surface_export','list_platforms_json','player'))",
	}],
]);

export function commandCatalog() {
	return [...COMMANDS.entries()].map(([id, command]) => ({
		id,
		description: command.description,
		params: command.params,
	}));
}

export function commandFromTemplate(template, params) {
	const entry = COMMANDS.get(template);
	if (!entry) { fail(404, "command template not found"); }
	const supplied = params && typeof params === "object" && !Array.isArray(params) ? Object.keys(params) : [];
	if (supplied.length !== 0) { fail(400, "command template does not accept parameters"); }
	const command = entry.build({});
	if (!commandSizeOk(command)) { fail(400, "command template exceeds size limit"); }
	return command;
}
