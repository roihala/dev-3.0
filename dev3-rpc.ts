#!/usr/bin/env bun
// Small RPC client for dev3-server's WebSocket. Used to drive the headless
// instance from the command line (validate install + add projects + spawn
// agents without a GUI).
//
// Usage:
//   bun dev3-rpc.ts <method> <json-params>
// Example:
//   bun dev3-rpc.ts addProject '{"path":"/home/foo/repo","name":"repo"}'

import { readFileSync, existsSync } from "node:fs";

function detectPort(): number {
	if (process.env.DEV3_PORT) return Number(process.env.DEV3_PORT);
	const logPath = `${process.env.HOME}/.dev3.0/logs/run-server.log`;
	if (existsSync(logPath)) {
		const txt = readFileSync(logPath, "utf8");
		const m = txt.match(/http:\/\/[^:]+:(\d+)\//);
		if (m) return Number(m[1]);
	}
	return 38493;
}

const PORT = detectPort();
const STATIC_CODE = process.env.DEV3_STATIC_CODE || "letmein-roi-2026";
const HOST = process.env.DEV3_HOST || `localhost:${PORT}`;

async function getSessionToken(): Promise<string> {
	const r = await fetch(`http://${HOST}/auth/exchange`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ token: STATIC_CODE }),
	});
	if (!r.ok) throw new Error(`auth/exchange: ${r.status} ${await r.text()}`);
	const j = (await r.json()) as { token: string };
	return j.token;
}

async function callRpc(method: string, params: unknown): Promise<unknown> {
	const session = await getSessionToken();
	return await new Promise((resolve, reject) => {
		const ws = new WebSocket(`ws://${HOST}/rpc?token=${encodeURIComponent(session)}`);
		const id = crypto.randomUUID();
		ws.onopen = () => {
			ws.send(JSON.stringify({ type: "request", id, method, params }));
		};
		ws.onmessage = (ev) => {
			const msg = JSON.parse(ev.data as string);
			if (msg.type === "response" && msg.id === id) {
				if (msg.success) resolve(msg.payload);
				else reject(new Error(msg.error || "RPC error"));
				ws.close();
			}
		};
		ws.onerror = (e: any) => reject(new Error(`WS error: ${e?.message ?? e}`));
		setTimeout(() => reject(new Error("RPC timeout")), 30_000);
	});
}

const [, , method, rawParams] = process.argv;
if (!method) {
	console.error("Usage: bun dev3-rpc.ts <method> [json-params]");
	process.exit(2);
}
const params = rawParams ? JSON.parse(rawParams) : {};
try {
	const result = await callRpc(method, params);
	console.log(JSON.stringify(result, null, 2));
} catch (err) {
	console.error("ERROR:", err instanceof Error ? err.message : String(err));
	process.exit(1);
}
