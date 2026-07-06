// Clusterio bridge - hardened HTTP shim over one persistent @clusterio/lib Control connection.
// Runs inside the controller container after the entrypoint reaches steady state.
// Pure helpers (auth, CIDR, limits, command templates) live in ./bridge-lib.mjs
// so they stay unit-testable without a cluster.
import http from "node:http";
import * as lib from "@clusterio/lib";
import {
	HttpError, fail,
	normalizeRemote, parseCidrs, cidrAllowed,
	tokenDigest, authOkHeader, makeRateLimiter,
	commandSizeOk, truncateOutput,
	commandCatalog, commandFromTemplate,
} from "./bridge-lib.mjs";

const CONFIG_PATH = process.env.BRIDGE_CONFIG || "/clusterio/tokens/config-control.json";
const PORT = parseInt(process.env.BRIDGE_PORT || "8100", 10);
const HOST = process.env.BRIDGE_BIND_HOST || "";
const TOKEN = process.env.BRIDGE_TOKEN || "";
const ALLOWED_CIDRS = parseCidrs(process.env.BRIDGE_ALLOWED_CIDRS || "");
const ALLOW_RAW = /^true$/i.test(process.env.BRIDGE_ALLOW_RAW || "false");
const MAX_BODY_BYTES = 8192;
const RATE_LIMIT_PER_MINUTE = 60;
const RATE_WINDOW_MS = 60_000;

if (!TOKEN) {
	console.error("[bridge] BRIDGE_TOKEN is required when BRIDGE_PORT is set");
	process.exit(1);
}
if (!HOST) {
	console.error("[bridge] BRIDGE_BIND_HOST is required when BRIDGE_PORT is set");
	process.exit(1);
}

class ControlConnector extends lib.WebSocketClientConnector {
	constructor(url, maxReconnectDelay, token) {
		super(url, maxReconnectDelay);
		this._token = token;
	}
	register() {
		this.sendHandshake(
			new lib.MessageRegisterControl(new lib.RegisterControlData(this._token, "2.0.0"))
		);
	}
}

class Control extends lib.Link {
	async shutdown() {
		try {
			await this.connector.disconnect();
		} catch (err) {
			if (!(lib.SessionLost && err instanceof lib.SessionLost)) {
				throw err;
			}
		}
	}
}

let control = null;
const rateLimitOk = makeRateLimiter(RATE_LIMIT_PER_MINUTE, RATE_WINDOW_MS);

function authOk(req) {
	return authOkHeader(req.headers.authorization || "", TOKEN);
}

function send(res, status, body) {
	res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
	res.end(JSON.stringify(body));
}

async function readJson(req) {
	let total = 0;
	const chunks = [];
	for await (const chunk of req) {
		total += chunk.length;
		if (total > MAX_BODY_BYTES) {
			fail(413, "request body too large");
		}
		chunks.push(chunk);
	}
	if (chunks.length === 0) { return {}; }
	try {
		return JSON.parse(Buffer.concat(chunks).toString("utf8"));
	} catch {
		fail(400, "invalid JSON body");
	}
}

async function initControl() {
	const cfg = await lib.ControlConfig.fromFile("control", CONFIG_PATH);
	const url = cfg.get("control.controller_url");
	const token = cfg.get("control.controller_token");
	const maxReconnectDelay = cfg.get("control.max_reconnect_delay") ?? 60;
	if (!url || !token) {
		throw new Error("control config is missing controller URL or token");
	}
	const connector = new ControlConnector(url, maxReconnectDelay, token);
	control = new Control(connector);
	await connector.connect();
	console.log("[bridge] connected to controller");
}

async function controllerRoundTrip() {
	await control.send(new lib.InstanceDetailsListRequest());
}

async function listInstances() {
	const list = await control.send(new lib.InstanceDetailsListRequest());
	return list.map((i) => ({
		id: i.id,
		name: i.name,
		status: i.status,
		host: i.assignedHost ?? null,
		factorioVersion: i.factorioVersion ?? null,
	}));
}

async function listHosts() {
	const list = await control.send(new lib.HostListRequest());
	return list.map((h) => ({
		id: h.id,
		name: h.name,
		status: h.connected ? "connected" : "disconnected",
	}));
}

async function getRunningInstance(instanceId) {
	if (!Number.isInteger(Number(instanceId))) { fail(400, "instanceId must be an integer"); }
	const id = Number(instanceId);
	const instances = await listInstances();
	const instance = instances.find((i) => i.id === id);
	if (!instance) { fail(404, "instance not found"); }
	if (instance.status !== "running") { fail(409, `instance is ${instance.status}`); }
	return instance;
}

async function sendRcon(instanceId, command) {
	await getRunningInstance(instanceId);
	const output = await control.sendTo({ instanceId: Number(instanceId) }, new lib.InstanceSendRconRequest(command));
	return truncateOutput(output);
}

async function handle(req, res) {
	const remoteIp = normalizeRemote(req.socket.remoteAddress);
	res.on("finish", () => {
		console.log(`[bridge] audit source=${remoteIp} method=${req.method} path=${req.url} status=${res.statusCode}`);
	});
	if (!cidrAllowed(remoteIp, ALLOWED_CIDRS)) {
		console.warn(`[bridge] rejected cidr source=${remoteIp}`);
		return send(res, 403, { error: "forbidden" });
	}
	if (!authOk(req)) {
		console.warn(`[bridge] failed auth source=${remoteIp}`);
		return send(res, 401, { error: "unauthorized" });
	}
	if (!rateLimitOk(tokenDigest(TOKEN).toString("hex"))) {
		return send(res, 429, { error: "rate limit exceeded" });
	}

	if (req.method === "GET" && req.url === "/health") {
		await controllerRoundTrip();
		return send(res, 200, { status: "ok" });
	}
	if (req.method === "GET" && req.url === "/instances") {
		return send(res, 200, await listInstances());
	}
	if (req.method === "GET" && req.url === "/hosts") {
		return send(res, 200, await listHosts());
	}
	if (req.method === "GET" && req.url === "/commands") {
		return send(res, 200, { commands: commandCatalog() });
	}
	if (req.method === "POST" && req.url === "/commands") {
		const { instanceId, template, params = {} } = await readJson(req);
		if (instanceId == null || typeof template !== "string") {
			fail(400, "instanceId and template required");
		}
		const command = commandFromTemplate(template, params);
		return send(res, 200, { output: await sendRcon(instanceId, command) });
	}
	if (req.method === "POST" && req.url === "/rcon") {
		if (!ALLOW_RAW) { return send(res, 403, { error: "raw RCON disabled" }); }
		const { instanceId, command } = await readJson(req);
		if (instanceId == null || !commandSizeOk(command)) {
			fail(400, "instanceId and command required; command must be <= 4096 bytes");
		}
		return send(res, 200, { output: await sendRcon(instanceId, command) });
	}
	return send(res, 404, { error: "not found" });
}

const server = http.createServer(async (req, res) => {
	try {
		await handle(req, res);
	} catch (err) {
		const status = err instanceof HttpError ? err.status : 502;
		const message = err instanceof HttpError ? err.message : "cluster request failed";
		console.error(`[bridge] request error status=${status}: ${err && (err.logMessage || err.message || err)}`);
		send(res, status, { error: message });
	}
});
server.requestTimeout = 10_000;
server.headersTimeout = 5_000;
server.keepAliveTimeout = 5_000;

(async () => {
	for (let attempt = 1; ; attempt++) {
		try {
			await initControl();
			break;
		} catch (err) {
			if (attempt >= 10) {
				console.error(`[bridge] could not connect to controller after ${attempt} attempts`);
				process.exit(1);
			}
			console.warn(`[bridge] connect attempt ${attempt} failed; retrying in 3s`);
			await new Promise((resolve) => setTimeout(resolve, 3000));
		}
	}
	server.listen(PORT, HOST, () => console.log(`[bridge] listening on ${HOST}:${PORT}`));
})();

for (const sig of ["SIGTERM", "SIGINT"]) {
	process.on(sig, async () => {
		server.close();
		if (control) {
			try { await control.shutdown(); } catch { /* best-effort shutdown */ }
		}
		process.exit(0);
	});
}
