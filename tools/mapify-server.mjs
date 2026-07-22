// Companion file writer for the Mapify Studio plugin.
// Receives serialized StarterGui subtrees over localhost HTTP and writes
// them into gui-sync/ following Argon's file-type conventions
// (https://argon.wiki/api/file-types). Deliberately NOT sync/StarterGui —
// argon serve must never watch this directory, or pushes here would sync
// straight back into the live Studio place.
//
// Usage:  node tools/mapify-server.mjs [--port 8123]

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const TARGET_DIR = path.join(PROJECT_ROOT, "gui-sync");
const MAX_BODY_BYTES = 256 * 1024 * 1024;

const portArgIndex = process.argv.indexOf("--port");
const PORT =
	portArgIndex !== -1
		? Number(process.argv[portArgIndex + 1])
		: Number(process.env.MAPIFY_PORT ?? 8123);

// Only ever-appended suffixes (never part of a sanitized instance name,
// which only has its *trailing* dots stripped) — lets us recover the
// original top-level key from a filename without mangling names that
// legitimately contain a dot (e.g. "V1.2.model.json" -> "V1.2").
const KNOWN_FILE_SUFFIXES = [".model.json", ".client.luau", ".server.luau", ".luau"];

function stripKnownSuffix(fileName) {
	for (const suffix of KNOWN_FILE_SUFFIXES) {
		if (fileName.endsWith(suffix)) {
			return fileName.slice(0, -suffix.length);
		}
	}
	return fileName;
}

function assertSafeComponent(name) {
	if (
		typeof name !== "string" ||
		name === "" ||
		name === "." ||
		name === ".." ||
		/[<>:"/\\|?*\x00-\x1f]/.test(name)
	) {
		throw new Error(`Unsafe file name component: ${JSON.stringify(name)}`);
	}
}

function prettyJson(value) {
	return JSON.stringify(value, null, "\t") + "\n";
}

// Writes a non-top-level Entry as a child inside dirPath (top-level entries
// use writeEntryAtomic instead, since they land directly at <key>.__tmp
// rather than at <dirPath>/<entry.name>).
function writeEntry(dirPath, entry) {
	if (entry.kind === "file") {
		assertSafeComponent(entry.fileName);
		const filePath = path.join(dirPath, entry.fileName);
		if (entry.json !== undefined) {
			fs.writeFileSync(filePath, prettyJson(entry.json));
		} else {
			fs.writeFileSync(filePath, entry.content ?? "");
		}
	} else if (entry.kind === "dir") {
		assertSafeComponent(entry.name);
		const subDir = path.join(dirPath, entry.name);
		fs.mkdirSync(subDir, { recursive: true });
		if (entry.initScript) {
			assertSafeComponent(entry.initScript.fileName);
			fs.writeFileSync(path.join(subDir, entry.initScript.fileName), entry.initScript.content ?? "");
		}
		if (entry.metaJson !== undefined) {
			fs.writeFileSync(path.join(subDir, "init.meta.json"), prettyJson(entry.metaJson));
		}
		for (const child of entry.children ?? []) {
			writeEntry(subDir, child);
		}
	} else {
		throw new Error(`Unknown entry kind: ${JSON.stringify(entry.kind)}`);
	}
}

// Every existing top-level path in TARGET_DIR, keyed by its sanitized base
// name (directories: exact name; files: name with a known suffix stripped).
function listTopLevel() {
	if (!fs.existsSync(TARGET_DIR)) return new Map();
	const result = new Map();
	for (const file of fs.readdirSync(TARGET_DIR)) {
		if (file.endsWith(".__tmp")) continue;
		const fullPath = path.join(TARGET_DIR, file);
		const isDir = fs.statSync(fullPath).isDirectory();
		const key = isDir ? file : stripKnownSuffix(file);
		result.set(key, fullPath);
	}
	return result;
}

// Writes one top-level Entry for `key` via a temp path + atomic rename, so a
// half-written subtree is never visible to anything reading gui-sync/.
function writeEntryAtomic(key, entry) {
	assertSafeComponent(key);
	const tmpPath = path.join(TARGET_DIR, `${key}.__tmp`);
	fs.rmSync(tmpPath, { recursive: true, force: true });

	if (entry.kind === "file") {
		if (entry.json !== undefined) {
			fs.writeFileSync(tmpPath, prettyJson(entry.json));
		} else {
			fs.writeFileSync(tmpPath, entry.content ?? "");
		}
	} else {
		fs.mkdirSync(tmpPath, { recursive: true });
		if (entry.initScript) {
			assertSafeComponent(entry.initScript.fileName);
			fs.writeFileSync(path.join(tmpPath, entry.initScript.fileName), entry.initScript.content ?? "");
		}
		if (entry.metaJson !== undefined) {
			fs.writeFileSync(path.join(tmpPath, "init.meta.json"), prettyJson(entry.metaJson));
		}
		for (const child of entry.children ?? []) {
			writeEntry(tmpPath, child);
		}
	}

	const finalName = entry.kind === "dir" ? entry.name : entry.fileName;
	assertSafeComponent(finalName);
	const finalPath = path.join(TARGET_DIR, finalName);

	fs.rmSync(finalPath, { recursive: true, force: true });
	fs.renameSync(tmpPath, finalPath);
}

function handlePush(payload) {
	const { selected, changed } = payload;
	if (!Array.isArray(selected) || !Array.isArray(changed)) {
		throw new Error("Payload must have `selected` and `changed` arrays");
	}

	fs.mkdirSync(TARGET_DIR, { recursive: true });

	const selectedSet = new Set(selected.map(String));

	let deleted = 0;
	for (const [key, fullPath] of listTopLevel()) {
		if (!selectedSet.has(key)) {
			fs.rmSync(fullPath, { recursive: true, force: true });
			deleted++;
		}
	}

	let written = 0;
	for (const { key, entry } of changed) {
		assertSafeComponent(key);
		// An entry can flip between file <-> dir across pushes (e.g. a script
		// gains/loses children) — clear any existing path for this key first,
		// since we can't assume its prior on-disk form matches the new one.
		for (const [existingKey, fullPath] of listTopLevel()) {
			if (existingKey === key) {
				fs.rmSync(fullPath, { recursive: true, force: true });
			}
		}
		writeEntryAtomic(key, entry);
		written++;
	}

	return { ok: true, deleted, written };
}

const server = http.createServer((req, res) => {
	const respond = (status, body) => {
		res.writeHead(status, { "Content-Type": "application/json" });
		res.end(JSON.stringify(body));
	};

	if (req.method === "GET" && req.url === "/ping") {
		return respond(200, { ok: true });
	}

	if (req.method === "POST" && req.url === "/push") {
		const chunks = [];
		let size = 0;
		req.on("data", (chunk) => {
			size += chunk.length;
			if (size > MAX_BODY_BYTES) {
				respond(413, { ok: false, error: "Payload too large" });
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on("end", () => {
			try {
				const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
				const result = handlePush(payload);
				console.log(
					`[${new Date().toLocaleTimeString()}] push: ${result.written} written, ${result.deleted} deleted`
				);
				respond(200, result);
			} catch (err) {
				console.error("Push failed:", err.message);
				respond(400, { ok: false, error: err.message });
			}
		});
		return;
	}

	respond(404, { ok: false, error: "Not found" });
});

server.listen(PORT, "127.0.0.1", () => {
	console.log(`Mapify server listening on http://127.0.0.1:${PORT}`);
	console.log(`Writing pushes to ${TARGET_DIR}`);
});
