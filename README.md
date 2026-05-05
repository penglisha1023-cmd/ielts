# IELTS Listening 题库聚合版

雅思听力机经题库的聚合 web 应用。学生可以注册登录、做题、听录音、做笔记,
跨设备同步进度与成绩。

- **前端**: 静态 HTML + JS,部署到 Vercel
- **后端**: Supabase (Auth + Postgres + Storage)
- **域名**: ielts.dnladvisory.com

---

## 一次性初始化

按下面顺序操作。**不会用 git/Vercel** 也能跑前两步预览 UI。

### 1. 数据库 schema 建表

打开 Supabase Dashboard → 项目 `ielts` → **SQL Editor → + New query** →
把 [`scripts/03-schema.sql`](./scripts/03-schema.sql) 全部内容粘进去 → 点 **Run**。

跑完应该看到 4 张表(`profiles` / `scores` / `notes` / `progress`),
以及一个 storage bucket `audio`。

### 2. 转换 88 个测试 HTML

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\01-build-tests.ps1
```

这会从 `D:\共享文件夹\桌面\IELTS Listening\` 读取所有原始 html,
转换后写入 `tests/<id>.html`。

### 3. 上传 88 个 mp3 到 Supabase Storage

a. 复制 `.env.local.example` → `.env.local`
b. 在 Supabase Dashboard → **Project Settings → API Keys → Secret keys** →
   复制 default secret key (`sb_secret_...`) → 填入 `.env.local`
c. 跑:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\02-upload-audio.ps1
```

约 5-10 分钟(取决于网速),350 MB 音频会上传到 `audio` bucket。

### 4. 推到 GitHub

```bash
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin git@github.com:<你>/ielts-listening.git
git push -u origin main
```

### 5. Vercel 部署

a. [vercel.com/new](https://vercel.com/new) → **Import Git Repository** → 选这个仓库
b. Framework preset: **Other** (因为没有 build step)
c. 直接点 **Deploy**
d. 部署完成 → Project → **Settings → Domains** → **Add** `ielts.dnladvisory.com`
e. Vercel 会给一条 CNAME 指向,去 DNS 商加这条记录(跟你之前 admin 子域同样操作)
f. 几分钟后 https://ielts.dnladvisory.com 生效

---

## 文件结构

```
ielts-listening-app/
├── index.html           # 登录 + 题库聚合首页
├── dashboard.html       # 我的成绩 + 笔记总览
├── lib/
│   ├── config.js        # 公开 Supabase URL / publishable key
│   ├── catalog.js       # 88 题目录(id / 标题 / 分组 / 频次)
│   ├── supabase.js      # Supabase 客户端 + auth/data helper
│   └── test-bridge.js   # 在测试页内运行的桥接(分数 / 进度 / 笔记同步)
├── tests/               # 88 个转换后的测试 html (build 脚本生成)
├── scripts/
│   ├── 01-build-tests.ps1
│   ├── 02-upload-audio.ps1
│   └── 03-schema.sql
├── vercel.json
├── .gitignore
├── .env.local.example
└── README.md
```

---

## 内容更新

- 想新增/修改一道题:把改后的源 html 放进 `D:\共享文件夹\桌面\IELTS Listening\<P>\<freq>\<id>. ...\`,
  重新跑 `01-build-tests.ps1`,git push,Vercel 自动重新部署。
- 想换音频:替换源文件夹里的 `audio.mp3`,重跑 `02-upload-audio.ps1`(直接覆盖)。

## 已知限制

- 跨设备做题:进度(答题填空、计时器)会自动同步;高亮和笔记的 DOM 位置依赖
  本地 localStorage,首次在新设备打开同一篇时,**笔记列表会出现**,但页面里
  原文上的高亮色块要等你重新点一下"Save"才会回到云端的 progress 表。
- Supabase 免费版每月 500 MB 数据库 + 1 GB Storage,几十个学生用足够。
- 需要 Supabase 项目里默认的邮箱注册功能开启(默认就开)。如果开启了"邮箱
  确认"(Project → Authentication → Providers → Email → Confirm email),
  学生注册后需要点邮件链接才能登录。要无验证直接登录,把那个开关关掉。
