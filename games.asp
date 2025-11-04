<%@LANGUAGE="JScript" CODEPAGE="65001"%>
<%
Response.CodePage = 65001;
Response.Charset = "utf-8";
Response.ContentType = "application/json";
Response.AddHeader("Cache-Control", "no-store, no-cache, must-revalidate");
Response.AddHeader("Pragma", "no-cache");
Response.AddHeader("Expires", "0");
applyCors();

var RETENTION_MS = 365 * 24 * 60 * 60 * 1000; // 1 year
var scriptPhysicalPath = safeTrim(Request.ServerVariables("PATH_TRANSLATED"));
var scriptDir = scriptPhysicalPath ? stripFileName(scriptPhysicalPath) : "";
if (!scriptDir) {
  scriptDir = safeMapPath(".") || ".";
}
var dataPath = joinPath(scriptDir, "data.json");
var dataPathSource = dataPath ? "scriptDir:data.json" : "fallback";
if (!dataPath) {
  dataPath = fallbackJoin(scriptDir, "data.json");
}
var dataLastReadPath = null;
var dataLastReadSource = null;
var method = String(Request.ServerVariables("REQUEST_METHOD"));
var gameId = getQueryValue("id");

try {
  if (method === "OPTIONS") {
    setStatus(204);
    Response.Write("");
  } else if (method === "GET") {
    if (!gameId) {
      throw httpError(400, "ID_REQUIRED", "\u7f3a\u5c11\u724c\u5c40 ID");
    }
    var data = readStore();
    if (!data.games.hasOwnProperty(gameId)) {
      throw httpError(404, "NOT_FOUND", "\u6307\u5b9a\u724c\u5c40\u4e0d\u5b58\u5728");
    }
    sendJson(200, { id: gameId, state: data.games[gameId] });
  } else if (method === "POST") {
    var payload = parseRequestBody();
    var bodyState = (payload && typeof payload.state === "object") ? payload.state : null;
    var data = readStore();
    if (gameId && !data.games.hasOwnProperty(gameId)) {
      gameId = "";
    }
    if (gameId) {
      if (!bodyState) {
        throw httpError(400, "STATE_REQUIRED", "\u7f3a\u5c11\u6709\u6548\u7684 state \u5b57\u6bb5");
      }
      var updated = normalizeStateForStore(bodyState, gameId, { meta: data.games[gameId].meta });
      data.games[gameId] = updated;
      writeStore(data);
      sendJson(200, { id: gameId, state: updated });
    } else {
      var initialState = bodyState || {};
      var newId = generateGameId(data.games);
      var stored = normalizeStateForStore(initialState, newId);
      data.games[newId] = stored;
      writeStore(data);
      sendJson(201, { id: newId, state: stored });
    }
  } else {
    Response.AddHeader("Allow", "GET, POST, OPTIONS");
    throw httpError(405, "METHOD_NOT_ALLOWED", "\u4e0d\u652f\u6301\u7684\u8bf7\u6c42\u65b9\u6cd5");
  }
} catch (ex) {
  var status = ex && ex.httpStatus ? ex.httpStatus : 500;
  setStatus(status);
  var errorPayload = buildErrorPayload(ex, status);
  var debugInfo = buildDebugInfo(ex);
  if (!debugInfo || typeof debugInfo !== "object") {
    debugInfo = {};
  }
  if (!debugInfo.dataPath) {
    debugInfo.dataPath = dataPath;
  }
  if (!debugInfo.scriptDir) {
    debugInfo.scriptDir = scriptDir;
  }
  if (!debugInfo.dataPathSource) {
    debugInfo.dataPathSource = dataPathSource;
  }
  if (!debugInfo.lastReadPath && dataLastReadPath) {
    debugInfo.lastReadPath = dataLastReadPath;
  }
  if (!debugInfo.lastReadSource && dataLastReadSource) {
    debugInfo.lastReadSource = dataLastReadSource;
  }
  errorPayload.debug = debugInfo;
  Response.Write(stringify(errorPayload));
}

Response.End();

function parseRequestBody() {
  var total = Request.TotalBytes;
  if (!total || total <= 0) {
    return {};
  }
  var bin = Request.BinaryRead(total);
  var stream = Server.CreateObject("ADODB.Stream");
  stream.Type = 1; // binary
  stream.Open();
  stream.Write(bin);
  stream.Position = 0;
  stream.Type = 2; // text
  stream.Charset = "utf-8";
  var text = stream.ReadText();
  stream.Close();
  if (!text || text === "") {
    return {};
  }
  try {
    return parseJson(text);
  } catch (e) {
    throw httpError(400, "INVALID_JSON", "\u65e0\u6cd5\u89e3\u6790\u4f20\u5165\u7684 JSON");
  }
}

function readStore() {
  var json = "";
  try {
    var fso = fileSystem();
    if (dataPath && fso.FileExists(dataPath)) {
      json = readFileUtf8(dataPath);
      dataLastReadPath = dataPath;
      dataLastReadSource = dataPathSource;
    }
  } catch (readErr) {
    json = "";
  }
  if (!json) {
    return { games: {} };
  }
  try {
    var data = parseJson(json);
    if (!data || typeof data !== "object") {
      return { games: {} };
    }
    if (!data.games || typeof data.games !== "object") {
      data.games = {};
    }
    return data;
  } catch (e) {
    return { games: {} };
  }
}

function writeStore(data) {
  var now = new Date().getTime();
  var payload = { games: {} };
  var games = data.games || {};
  for (var id in games) {
    if (!games.hasOwnProperty(id)) continue;
    var game = games[id];
    var createdAt = 0;
    if (game && game.meta && game.meta.createdAt) {
      var stamp = Date.parse(game.meta.createdAt);
      if (!isNaN(stamp)) {
        createdAt = stamp;
      }
    }
    if (createdAt > 0 && (now - createdAt) > RETENTION_MS) {
      continue;
    }
    if (!createdAt) {
      createdAt = now;
      if (game.meta) {
        game.meta.createdAt = (new Date(createdAt)).toISOString ? (new Date(createdAt)).toISOString() : formatIsoDate(new Date(createdAt));
      }
    }
    payload.games[id] = game;
  }
  try {
    writeFileUtf8(dataPath, stringify(payload));
  } catch (writeErr) {
    var wrapped = httpError(500, "WRITE_FAILED", "\u5199\u5165\u6587\u4ef6\u5931\u8d25");
    wrapped.inner = writeErr;
    wrapped.payload.dataPath = dataPath;
    wrapped.payload.dataPathSource = dataPathSource;
    throw wrapped;
  }
}

function normalizeStateForStore(state, id, defaults) {
  var now = new Date();
  var nowIso = now.toISOString ? now.toISOString() : formatIsoDate(now);
  var clone = cloneObject(state || {});
  var defaultsMeta = (defaults && defaults.meta && typeof defaults.meta === "object") ? defaults.meta : {};
  var incomingMeta = (clone.meta && typeof clone.meta === "object") ? clone.meta : {};
  var meta = {};
  assign(meta, defaultsMeta);
  assign(meta, incomingMeta);
  if (!meta.createdAt) {
    meta.createdAt = nowIso;
  }
  meta.updatedAt = nowIso;
  meta.id = id;
  clone.meta = meta;
  return clone;
}

function formatIsoDate(date) {
  if (!date) {
    date = new Date();
  }
  if (date.toISOString) {
    return date.toISOString();
  }
  function pad2(n) {
    return ("0" + n).slice(-2);
  }
  function pad3(n) {
    n = n || 0;
    return ("00" + n).slice(-3);
  }
  return date.getUTCFullYear() + "-" +
    pad2(date.getUTCMonth() + 1) + "-" +
    pad2(date.getUTCDate()) + "T" +
    pad2(date.getUTCHours()) + ":" +
    pad2(date.getUTCMinutes()) + ":" +
    pad2(date.getUTCSeconds()) + "." +
    pad3(date.getUTCMilliseconds()) + "Z";
}

function generateGameId(games) {
  var datePart = todayStamp();
  var maxSeq = 0;
  for (var key in games) {
    if (!games.hasOwnProperty(key)) continue;
    if (key.indexOf(datePart) === 0 && key.length === datePart.length + 4) {
      var seq = parseInt(key.substr(datePart.length), 10);
      if (!isNaN(seq) && seq > maxSeq) {
        maxSeq = seq;
      }
    }
  }
  var nextSeq = ("0000" + (maxSeq + 1)).slice(-4);
  return datePart + nextSeq;
}

function todayStamp() {
  var now = new Date();
  var y = now.getFullYear();
  var m = ("0" + (now.getMonth() + 1)).slice(-2);
  var d = ("0" + now.getDate()).slice(-2);
  return "" + y + m + d;
}

function assign(target, source) {
  if (!source) return;
  for (var key in source) {
    if (source.hasOwnProperty(key)) {
      target[key] = source[key];
    }
  }
}

function cloneObject(obj) {
  return parseJson(stringify(obj || {}));
}

function buildErrorPayload(error, status) {
  var payload = { ok: false };
  if (error && error.payload && typeof error.payload === "object") {
    assign(payload, error.payload);
  }
  payload.ok = false;
  if (typeof payload.error_code === "undefined") {
    payload.error_code = extractErrorNumber(error, status);
  }
  if (!payload.error_msg) {
    var message = extractErrorMessage(error);
    if (message) {
      payload.error_msg = message;
    } else {
      payload.error_msg = "UNKNOWN";
    }
  }
  if (!payload.error && error && error.payload && typeof error.payload.error === "string") {
    payload.error = error.payload.error;
  }
  if (!payload.error) {
    payload.error = "SERVER_ERROR";
  }
  return payload;
}

function extractErrorNumber(error, fallback) {
  if (error && typeof error.number === "number") {
    return error.number;
  }
  if (typeof fallback === "number") {
    return fallback;
  }
  return -1;
}

function extractErrorMessage(error) {
  if (!error) return "";
  if (error.description) return String(error.description);
  if (error.message) return String(error.message);
  return "";
}

function parseJson(text) {
  if (typeof JSON !== "undefined" && JSON.parse) {
    return JSON.parse(text);
  }
  return eval('(' + text + ')');
}

function stringify(value) {
  if (typeof JSON !== "undefined" && JSON.stringify) {
    return JSON.stringify(value);
  }
  return fallbackStringify(value);
}

function fallbackStringify(value) {
  if (value === null) return "null";
  var type = typeof value;
  if (type === "number" || type === "boolean") {
    return String(value);
  }
  if (type === "string") {
    return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r/g, '\\r').replace(/\n/g, '\\n').replace(/\t/g, '\\t').replace(/[\u0000-\u001F]/g, function (c) {
      var code = c.charCodeAt(0).toString(16);
      return "\\u" + ("000" + code).slice(-4);
    }) + '"';
  }
  if (type === "object") {
    if (value instanceof Array) {
      var arr = [];
      for (var i = 0; i < value.length; i++) {
        arr.push(fallbackStringify(value[i]));
      }
      return "[" + arr.join(",") + "]";
    }
    var props = [];
    for (var key in value) {
      if (value.hasOwnProperty(key) && typeof value[key] !== "undefined") {
        props.push(fallbackStringify(String(key)) + ":" + fallbackStringify(value[key]));
      }
    }
    return "{" + props.join(",") + "}";
  }
  return "null";
}

function readFileUtf8(path) {
  var stream = Server.CreateObject("ADODB.Stream");
  stream.Type = 2;
  stream.Charset = "utf-8";
  stream.Open();
  stream.LoadFromFile(path);
  var text = stream.ReadText();
  stream.Close();
  return text;
}

function writeFileUtf8(path, text) {
  var stream = Server.CreateObject("ADODB.Stream");
  stream.Type = 2;
  stream.Charset = "utf-8";
  stream.Open();
  stream.WriteText(text);
  stream.Position = 0;
  stream.Type = 1;
  var fso = null;
  try {
    fso = fileSystem();
  } catch (fsErr) {
    fso = null;
  }
  if (fso && path) {
    try {
      if (fso.FileExists(path)) {
        var file = fso.GetFile(path);
        var attrs = file.Attributes;
        var readOnly = 1;
        if ((attrs & readOnly) === readOnly) {
          file.Attributes = attrs & (~readOnly);
        }
      }
      var folderPath = stripFileName(path);
      if (folderPath && !fso.FolderExists(folderPath)) {
        fso.CreateFolder(folderPath);
      }
    } catch (attrErr) {
      // ignore attribute adjustments
    }
  }
  try {
    stream.SaveToFile(path, 2);
  } finally {
    stream.Close();
  }
}

function fileSystem() {
  if (!fileSystem.cache) {
    fileSystem.cache = Server.CreateObject("Scripting.FileSystemObject");
  }
  return fileSystem.cache;
}

function safeMapPath(path) {
  try {
    return Server.MapPath(path);
  } catch (err) {
    return "";
  }
}

function safeTrim(value) {
  if (value === null || typeof value === "undefined") return "";
  var text = String(value).replace(/^\s+|\s+$/g, "");
  var lower = text.toLowerCase();
  if (lower === "undefined" || lower === "null") {
    return "";
  }
  return text;
}

function stripFileName(path) {
  var text = safeTrim(path);
  if (!text) return "";
  var idxBack = text.lastIndexOf("\\");
  var idxForward = text.lastIndexOf("/");
  var idx = idxBack > idxForward ? idxBack : idxForward;
  if (idx <= 0) {
    return "";
  }
  return text.substring(0, idx);
}

function joinPath(base, leaf) {
  var root = safeTrim(base);
  if (!root) {
    return safeTrim(leaf);
  }
  var separator = "\\";
  if (root.indexOf("/") !== -1 && root.indexOf("\\") === -1) {
    separator = "/";
  }
  var lastChar = root.charAt(root.length - 1);
  if (lastChar !== "\\" && lastChar !== "/") {
    root += separator;
  }
  return root + leaf;
}

function fallbackJoin(base, leaf) {
  var root = safeTrim(base);
  if (!root) {
    root = ".";
  }
  var lastChar = root.charAt(root.length - 1);
  var separator = "\\";
  if (root.indexOf("/") !== -1 && root.indexOf("\\") === -1) {
    separator = "/";
  }
  if (lastChar !== "\\" && lastChar !== "/") {
    root += separator;
  }
  return root + leaf;
}

function getQueryValue(name) {
  if (!name) return "";
  var raw = Request.QueryString(name);
  if (raw === null || typeof raw === "undefined") {
    return "";
  }
  try {
    if (typeof raw.Count === "number" && raw.Count > 0) {
      var value = raw.Item(1);
      return safeTrim(value);
    }
  } catch (err) {
  }
  return safeTrim(raw);
}

function buildDebugInfo(error) {
  var info = {};
  if (!error) {
    return info;
  }
  if (error.message) {
    info.message = String(error.message);
  }
  if (typeof error.number !== "undefined") {
    info.number = error.number;
    try {
      info.numberHex = "0x" + (error.number >>> 0).toString(16).toUpperCase();
    } catch (hexErr) {
      info.numberHex = "";
    }
  }
  if (error.description) {
    info.description = String(error.description);
  }
  if (error.source) {
    info.source = String(error.source);
  }
  if (error.stack) {
    info.stack = String(error.stack);
  }
  if (typeof error.lineNumber !== "undefined") {
    info.lineNumber = error.lineNumber;
  }
  if (error.inner) {
    var inner = error.inner;
    try {
      if (inner.message && !info.innerMessage) {
        info.innerMessage = String(inner.message);
      }
      if (typeof inner.number !== "undefined" && typeof info.innerNumber === "undefined") {
        info.innerNumber = inner.number;
      }
      if (inner.description && !info.innerDescription) {
        info.innerDescription = String(inner.description);
      }
      if (inner.source && !info.innerSource) {
        info.innerSource = String(inner.source);
      }
    } catch (innerErr) {
    }
  }
  return info;
}

function httpError(status, code, message) {
  var err = new Error(message || code);
  err.httpStatus = status;
  err.payload = { error: code };
  if (message) {
    err.payload.message = message;
  }
  err.number = status;
  return err;
}

function sendJson(status, payload) {
  setStatus(status);
  var body = {};
  if (payload && typeof payload === "object") {
    assign(body, payload);
  }
  body.ok = true;
  Response.Write(stringify(body));
}

function setStatus(code) {
  var map = {
    204: "204 No Content",
    200: "200 OK",
    201: "201 Created",
    400: "400 Bad Request",
    404: "404 Not Found",
    405: "405 Method Not Allowed",
    500: "500 Internal Server Error"
  };
  var text = map[code] || (code + "");
  Response.Status = text;
}

function applyCors() {
  Response.AddHeader("Access-Control-Allow-Origin", "*");
  Response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  Response.AddHeader("Access-Control-Allow-Headers", "Content-Type");
}
%>




















