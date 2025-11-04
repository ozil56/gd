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
var dataPath = Server.MapPath("../data.json");
var method = String(Request.ServerVariables("REQUEST_METHOD"));
var gameId = Request.QueryString("id");

try {
  if (method === "OPTIONS") {
    setStatus(204);
    Response.Write("");
  } else if (method === "GET") {
    if (!gameId) {
      throw httpError(400, "ID_REQUIRED", "缺少牌局 ID");
    }
    var data = readStore();
    if (!data.games.hasOwnProperty(gameId)) {
      throw httpError(404, "NOT_FOUND", "指定牌局不存在");
    }
    sendJson(200, { id: gameId, state: data.games[gameId] });
  } else if (method === "POST") {
    var payload = parseRequestBody();
    var initialState = (payload && typeof payload.state === "object") ? payload.state : {};
    var data = readStore();
    var newId = generateGameId(data.games);
    var stored = normalizeStateForStore(initialState, newId);
    data.games[newId] = stored;
    writeStore(data);
    sendJson(201, { id: newId, state: stored });
  } else if (method === "PUT") {
    if (!gameId) {
      throw httpError(400, "ID_REQUIRED", "缺少牌局 ID");
    }
    var updatePayload = parseRequestBody();
    var nextState = (updatePayload && typeof updatePayload.state === "object") ? updatePayload.state : null;
    if (!nextState) {
      throw httpError(400, "STATE_REQUIRED", "请求体缺少有效的 state 字段");
    }
    var data = readStore();
    if (!data.games.hasOwnProperty(gameId)) {
      throw httpError(404, "NOT_FOUND", "指定牌局不存在");
    }
    var stored = normalizeStateForStore(nextState, gameId, { meta: data.games[gameId].meta });
    data.games[gameId] = stored;
    writeStore(data);
    sendJson(200, { id: gameId, state: stored });
  } else {
    Response.AddHeader("Allow", "GET, POST, PUT, OPTIONS");
    throw httpError(405, "METHOD_NOT_ALLOWED", "不支持的请求方法");
  }
} catch (ex) {
  var status = ex && ex.httpStatus ? ex.httpStatus : 500;
  setStatus(status);
  Response.Write(stringify(buildErrorPayload(ex, status)));
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
    throw httpError(400, "INVALID_JSON", "无法解析请求体 JSON");
  }
}

function readStore() {
  var json = "";
  if (fileSystem().FileExists(dataPath)) {
    json = readFileUtf8(dataPath);
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
    if (!createdAt || (now - createdAt) > RETENTION_MS) {
      continue;
    }
    payload.games[id] = game;
  }
  writeFileUtf8(dataPath, stringify(payload));
}

function normalizeStateForStore(state, id, defaults) {
  var nowIso = (new Date()).toISOString();
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
  stream.SaveToFile(path, 2);
  stream.Close();
}

function fileSystem() {
  if (!fileSystem.cache) {
    fileSystem.cache = Server.CreateObject("Scripting.FileSystemObject");
  }
  return fileSystem.cache;
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
  Response.AddHeader("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS");
  Response.AddHeader("Access-Control-Allow-Headers", "Content-Type");
}
%>
