# 掼蛋记分器 2.0

基于文件存储的掼蛋记分器，支持通过牌局 ID 分享即时比分。

## 快速开始

### 方案 A：Node.js（开发/调试环境）

1. 安装依赖：
   ```bash
   npm install
   ```
   > 在某些离线/内网环境中如无法访问 npm 仓库，请预先下载 `express` 并放入 `node_modules`。
2. 启动服务：
   ```bash
   npm start
   ```
3. 浏览器访问 `http://localhost:3000/index.html`。首次访问会自动创建当日首个牌局并生成形如 `202511040001` 的牌局 ID。

### 方案 B：Classic ASP（生产/共享空间）

如果目标服务器仅支持 Classic ASP，可直接部署 `index.html`、`data.json` 以及 `api/games.asp`：

1. 将仓库内容拷贝至站点根目录，确保 `data.json` 具有写入权限。
2. 访问 `index.html` 即可使用。前端会请求 `api/games.asp` 来创建、读取和更新牌局。
3. 若需要在同一站点托管多个应用，请确保 `api/games.asp` 的目录结构保持 `index.html` 同级的 `api/` 子目录。

## 牌局分享

- 地址格式：`/index.html?id=<牌局ID>`。只需将完整链接分享给同桌玩家，即可实时查看并操作同一牌局。
- 顶部「复制链接」按钮会复制当前牌局的完整访问链接，便于群聊粘贴。
- 「新牌局」按钮会生成新的牌局 ID 并重置比分，适用于下一局游戏。

## 数据存储

- 临时数据存储在根目录的 `data.json` 中，结构为：
  ```json
  {
    "games": {
      "202511040001": { "aLevel": 0, ... }
    }
  }
  ```
- 服务端会在每次写入时清理超过 1 年未更新的牌局，避免文件无限增长。
- 若需要长期归档，可手动备份 `data.json` 或使用页面内的 JSON 导出功能。

## 项目结构

```
├── index.html    # 前端界面与逻辑
├── server.js     # Express 文件存储后端（可选）
├── api/
│   └── games.asp # Classic ASP 文件存储后端
├── data.json     # 牌局数据（运行时写入）
├── package.json  # 项目依赖
└── README.md     # 本说明文档
```

祝各位玩得开心，炸弹不断！
