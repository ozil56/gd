const express = require('express');
const fs = require('fs/promises');
const path = require('path');

const app = express();
const DATA_FILE = path.join(__dirname, 'data.json');
const PORT = process.env.PORT || 3000;
const RETENTION_MS = 365 * 24 * 60 * 60 * 1000; // 1 year

app.use(express.json({ limit: '1mb' }));
app.use(express.static(__dirname));

async function readStore(){
  try{
    const raw = await fs.readFile(DATA_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    if(!parsed || typeof parsed !== 'object'){ return { games: {} }; }
    if(!parsed.games || typeof parsed.games !== 'object'){ parsed.games = {}; }
    return parsed;
  }catch(err){
    if(err.code === 'ENOENT'){
      return { games: {} };
    }
    throw err;
  }
}

async function writeStore(data){
  const now = Date.now();
  const payload = { games: {} };
  for(const [id, game] of Object.entries(data.games || {})){
    const createdAt = game && game.meta ? new Date(game.meta.createdAt || 0).getTime() : 0;
    if(!createdAt || (now - createdAt) > RETENTION_MS){
      continue;
    }
    payload.games[id] = game;
  }
  await fs.writeFile(DATA_FILE, JSON.stringify(payload, null, 2), 'utf8');
}

function todayStamp(){
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  return `${y}${m}${d}`;
}

function generateGameId(games){
  const datePart = todayStamp();
  let maxSeq = 0;
  const pattern = new RegExp(`^${datePart}(\\d{4})$`);
  for(const id of Object.keys(games)){
    const match = id.match(pattern);
    if(match){
      const seq = parseInt(match[1], 10);
      if(seq > maxSeq){
        maxSeq = seq;
      }
    }
  }
  const nextSeq = (maxSeq + 1).toString().padStart(4, '0');
  return `${datePart}${nextSeq}`;
}

function normalizeStateForStore(state, id, defaults={}){
  const nowIso = new Date().toISOString();
  const incoming = (state && typeof state === 'object') ? state : {};
  const meta = Object.assign({}, defaults.meta || {}, incoming.meta || {});
  if(!meta.createdAt){
    meta.createdAt = nowIso;
  }
  meta.updatedAt = nowIso;
  meta.id = id;
  return Object.assign({}, incoming, { meta });
}

app.get('/api/games/:id', async (req, res) => {
  const data = await readStore();
  const id = req.params.id;
  const game = data.games[id];
  if(!game){
    return res.status(404).json({ error: 'NOT_FOUND' });
  }
  res.json({ id, state: game });
});

app.post('/api/games', async (req, res) => {
  const data = await readStore();
  const id = generateGameId(data.games || {});
  const stored = normalizeStateForStore(req.body ? req.body.state : null, id);
  data.games = Object.assign({}, data.games, { [id]: stored });
  await writeStore(data);
  res.status(201).json({ id, state: stored });
});

app.put('/api/games/:id', async (req, res) => {
  const id = req.params.id;
  const incoming = req.body ? req.body.state : null;
  if(!incoming || typeof incoming !== 'object'){
    return res.status(400).json({ error: 'STATE_REQUIRED' });
  }
  const data = await readStore();
  if(!data.games[id]){
    return res.status(404).json({ error: 'NOT_FOUND' });
  }
  const stored = normalizeStateForStore(incoming, id, { meta: data.games[id].meta });
  data.games[id] = stored;
  await writeStore(data);
  res.json({ id, state: stored });
});

app.listen(PORT, () => {
  console.log(`Guandan scorekeeper server running at http://localhost:${PORT}`);
});
