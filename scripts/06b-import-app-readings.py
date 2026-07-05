# -*- coding: utf-8 -*-
"""
06b-import-app-readings.py

Generate standalone reading *source* HTML from the reading-app's exam JS data
(assets/generated/reading-exams/p*.js), matching the site's existing source
template (see P1高频/12. P1 - Rubber.html). Output goes to the canonical source
tree that scripts/06-build-readings.ps1 consumes:
   <SRC_ROOT>/P{n}{高频|次高频}/<id>. P{n} - <EnglishTitle>.html
so a subsequent 06-build run picks them up and regenerates readings/ + catalog.

id   = leading number of meta.pdfFilename.
freq = meta.frequency: high -> 高频 ; medium/low -> 次高频.
Handles radio / text / select / checkbox (incl. combined names like q8_9,
q12-13-14, and array answer keys), and converts every drag-drop variant
(in-group match-dropzone, passage-embedded matching-headings, and the
draggable-word bank) into standard radio/select inputs. Every generated page is
self-verified: if any answerKey question lacks a gradeable input the file is
flagged and NOT written.

Usage:
   python scripts/06b-import-app-readings.py <exam-file-list.txt> [out_root]
     <exam-file-list.txt>  one exam js basename per line (e.g. p1-high-229.js)
     [out_root]            defaults to SRC_ROOT (the canonical source tree)
Then run:  powershell -ExecutionPolicy Bypass -File .\scripts\06-build-readings.ps1

Override EXAM_DIR / SRC_ROOT via env vars READING_EXAM_DIR / READING_SRC_ROOT.
"""
import re, json, os, sys, html as _html

EXAM_DIR = os.environ.get("READING_EXAM_DIR",
    r"D:/共享文件夹/桌面/ielts-listening-app/5月阅读/assets/generated/reading-exams")
SRC_ROOT = os.environ.get("READING_SRC_ROOT",
    r"D:/共享文件夹/桌面/雅思英语听力/网页应用版/阅读")

def extract_payload(path):
    s = open(path, encoding='utf-8').read()
    i = s.find('.register(')
    b = s.find('{', i)
    depth = 0; instr = False; esc = False; end = -1
    for j in range(b, len(s)):
        c = s[j]
        if instr:
            if esc: esc = False
            elif c == '\\': esc = True
            elif c == '"': instr = False
        else:
            if c == '"': instr = True
            elif c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    end = j + 1; break
    return json.loads(s[b:end])

def strip_cjk(t):
    # remove CJK chars and tidy whitespace; keep ascii title
    t = re.sub(r'[　-鿿＀-￯]+', ' ', t)
    # drop empty bracket residue left by CJK removal
    t = re.sub(r'[\(\（]\s*[\)\）]', ' ', t)
    t = re.sub(r'[\[\【]\s*[\]\】]', ' ', t)
    t = re.sub(r'\s+', ' ', t).strip(' -_')
    # drop a leading internal numeric code token (e.g. "1018 Looking...") but keep "3D ..."
    t = re.sub(r'^\d{3,}\s+(?=[A-Za-z])', '', t)
    return t.strip()

def passage_html(d):
    blocks = d.get('passage', {}).get('blocks', [])
    parts = []
    for blk in blocks:
        h = blk.get('html') or blk.get('bodyHtml') or ''
        # safety: cut any trailing structural junk from imported fragments
        cut = h.find('</section>')
        if cut != -1:
            h = h[:cut]
        parts.append(h)
    return '\n'.join(parts).strip()

def convert_drag_group(body):
    """Convert match-dropzone/drag-item matching into radio buttons.

    Each drag-item carries a short option value (data-option, e.g. "A"/"iii")
    plus a full label (e.g. "A Giulio Tononi" or "iii The initial emergence").
    We render compact radios keyed on the short value (to match answerKey),
    and, when labels carry extra text, a visible "List of Options" box.
    """
    if 'match-dropzone' not in body:
        return body  # dropzones not in this group; handled by passage/word-bank passes
    # collect options in document order: (value, full_label)
    opts = []; seen = set()
    for m in re.finditer(r'<div[^>]*class="[^"]*drag-item[^"]*"[^>]*>(.*?)</div>', body, re.S):
        full = m.group(0)
        inner = re.sub(r'<[^>]+>', ' ', m.group(1)).replace('&nbsp;', ' ')
        inner = re.sub(r'\s+', ' ', inner).strip()
        dm = re.search(r'data-(?:option|heading|key)="([^"]*)"', full)
        val = dm.group(1).strip() if (dm and dm.group(1).strip()) else (inner.split(' ')[0] if inner else '')
        label = inner if inner else val
        if val and val not in seen:
            seen.add(val); opts.append((val, label))
    # remove drag-item pool container(s) and any stray items
    body = re.sub(r'<div[^>]*class="(?:drag-items|drag-pool|drag-container|options-pool|drag-item-pool|drag-bank|draggable-items|drag-source)"[^>]*>.*?</div>\s*', '', body, flags=re.S)
    body = re.sub(r'<div[^>]*class="[^"]*drag-item[^"]*"[^>]*>.*?</div>', '', body, flags=re.S)
    # replace each dropzone with compact radios (value + short value shown)
    def repl(m):
        tag = m.group(0)
        qm = re.search(r'data-question="([^"]+)"', tag)
        if not qm:
            return tag
        q = qm.group(1)
        labels = ''.join(
            '<label style="margin-right:10px; white-space:nowrap;"><input type="radio" name="%s" value="%s"> %s</label>'
            % (q, _html.escape(v, quote=True), _html.escape(v)) for v, _ in opts)
        return '<div class="match-options" style="margin:6px 0;">%s</div>' % labels
    body = re.sub(r'<div[^>]*class="[^"]*match-dropzone[^"]*"[^>]*>.*?</div>', repl, body, flags=re.S)
    # if labels carry meaning beyond the bare value, show an options list box
    if opts and any(lbl != v for v, lbl in opts):
        box = ('<div class="headings"><p><strong>List of Options</strong></p>'
               + ''.join('<div>%s</div>' % _html.escape(lbl) for v, lbl in opts)
               + '</div>')
        if '</h4>' in body:
            body = body.replace('</h4>', '</h4>' + box, 1)
        else:
            body = box + body
    return body

def _collect_pool(html, cls, attr):
    """Collect (value, full_label) options from drag-item/draggable-word elements."""
    opts = []; seen = set()
    pat = r'<(?:div|span)[^>]*class="[^"]*%s[^"]*"[^>]*>(.*?)</(?:div|span)>' % cls
    for m in re.finditer(pat, html, re.S):
        full = m.group(0)
        inner = re.sub(r'<[^>]+>', ' ', m.group(1)).replace('&nbsp;', ' ')
        inner = re.sub(r'\s+', ' ', inner).strip()
        am = re.search(attr + r'="([^"]*)"', full)
        val = am.group(1).strip() if (am and am.group(1).strip()) else (inner.split(' ')[0] if inner else '')
        if val and val not in seen:
            seen.add(val); opts.append((val, inner or val))
    return opts

def convert_passage_matching(passage, qbody):
    """166-type: match-dropzone answer boxes embedded in the passage + a
    headings-pool (data-heading) in the questions. Build a proper matching
    question block in the question pane and strip the passage answer boxes."""
    if 'match-dropzone' not in passage:
        return passage, qbody
    # map question -> paragraph label from passage dropzones (in order)
    pairs = []
    for m in re.finditer(r'<div[^>]*class="[^"]*match-dropzone[^"]*"[^>]*>.*?</div>', passage, re.S):
        tag = m.group(0)
        qm = re.search(r'data-question="([^"]+)"', tag)
        pm = re.search(r'data-paragraph="([^"]+)"', tag)
        if qm:
            pairs.append((qm.group(1), pm.group(1) if pm else ''))
    # strip the answer-box dropzones from the passage (keep paragraph text)
    passage = re.sub(r'<div[^>]*class="[^"]*match-dropzone[^"]*"[^>]*>.*?</div>', '', passage, flags=re.S)
    # option pool = headings pool in questions
    opts = _collect_pool(qbody, 'drag-item', 'data-heading') or _collect_pool(qbody, 'drag-item', 'data-option')
    # remove the headings-pool container(s) from questions
    qbody = re.sub(r'<div[^>]*class="[^"]*headings-pool[^"]*"[^>]*>.*?</div>\s*(?:</div>)?', '', qbody, flags=re.S)
    qbody = re.sub(r'<div[^>]*class="[^"]*pool-items[^"]*"[^>]*>.*?</div>', '', qbody, flags=re.S)
    qbody = re.sub(r'<div[^>]*class="drag-item"[^>]*>.*?</div>', '', qbody, flags=re.S)
    # build headings box + radio rows
    box = ('<div class="headings"><p><strong>List of Headings</strong></p>'
           + ''.join('<div>%s</div>' % _html.escape(lbl) for v, lbl in opts) + '</div>')
    rows = []
    for q, para in pairs:
        radios = ''.join(
            '<label style="margin-right:10px; white-space:nowrap;"><input type="radio" name="%s" value="%s"> %s</label>'
            % (q, _html.escape(v, quote=True), _html.escape(v)) for v, _ in opts)
        para_lbl = ('Paragraph %s' % para) if para else q
        rows.append('<div class="match-question-item"><p><strong>%s</strong></p>%s</div>' % (_html.escape(para_lbl), radios))
    block = box + '\n' + '\n'.join(rows)
    # inject into the questions: after the instructions of the group that held the pool.
    # Simplest robust approach: append as its own group at the very top of qbody's
    # first group if a placeholder remains, else append a fresh group.
    inject = '<div class="group">%s</div>' % block
    # place right after the intro <h3>Questions</h3> if present, else prepend
    if '</h3>' in qbody:
        qbody = qbody.replace('</h3>', '</h3>\n' + inject, 1)
    else:
        qbody = inject + qbody
    return passage, qbody

def convert_word_bank(passage, qbody):
    """164-type: inline drop-target-summary spans + a draggable-word bank.
    Replace each target span with a <select> of the word-bank options."""
    if 'drop-target-summary' not in qbody and 'draggable-word' not in qbody:
        return passage, qbody
    opts = _collect_pool(qbody, 'draggable-word', 'data-key')
    if not opts:
        return passage, qbody
    options_html = '<option value="">—</option>' + ''.join(
        '<option value="%s">%s</option>' % (_html.escape(v, quote=True), _html.escape(lbl)) for v, lbl in opts)
    def repl(m):
        tag = m.group(0)
        qm = re.search(r'data-question="([^"]+)"', tag)
        if not qm:
            return tag
        return '<select name="%s">%s</select>' % (qm.group(1), options_html)
    qbody = re.sub(r'<(?:span|div)[^>]*class="[^"]*drop-target-summary[^"]*"[^>]*>.*?</(?:span|div)>', repl, qbody, flags=re.S)
    return passage, qbody

def verify_page(answer_key, full_html):
    """Return list of answerKey ids that have no gradeable input in the page."""
    missing = []
    for q in answer_key:
        if re.search(r'name="%s"' % re.escape(q), full_html):
            continue
        # combined checkbox group covering q (e.g. name="q8_9" or "q12-13-14")
        found = False
        for m in re.finditer(r'name="(q\d+(?:[-_]\d+)+)"', full_html):
            parts = re.split(r'[-_]', m.group(1))
            ids = [parts[0]] + ['q' + p for p in parts[1:]]
            if q in ids:
                found = True; break
        if not found:
            missing.append(q)
    return missing

def questions_html(d):
    intro = d.get('meta', {}).get('questionIntroHtml') or '<h3>Questions</h3>'
    groups = d.get('questionGroups', [])
    parts = [intro]
    for g in groups:
        parts.append(convert_drag_group(g.get('bodyHtml', '')))
    return '\n\n'.join(parts).strip()

def answerkey_js(ak):
    lines = []
    for k, v in ak.items():
        if isinstance(v, list):
            arr = '[' + ', '.join(json.dumps(str(x)) for x in v) + ']'
            lines.append('  %s: %s' % (json.dumps(k), arr))
        else:
            lines.append('  %s: %s' % (json.dumps(k), json.dumps(str(v))))
    return '{\n' + ',\n'.join(lines) + '\n}'

# ---- template pieces (from the canonical Rubber source) ----
HEAD_STYLE = r'''<style>
  * { box-sizing: border-box; margin:0; padding:0; }
  html,body { height:100%; }
  body { font-family: Arial, sans-serif; background:#f5f5f5; }
  #timer { position:fixed; top:12px; right:12px; background:#fff; border:1px solid #ddd; border-radius:6px; padding:8px 12px; font-size:16px; font-weight:600; color:#0066cc; z-index:1000; }
  .shell { display:flex; height:100vh; width:100%; }
  .pane { background:#fff; overflow:auto; padding:24px; }
  #left { flex: 0 0 50%; border-right:1px solid #ddd; }
  #right { flex: 1 1 auto; background:#fafafa; }
  #divider { flex: 0 0 5px; background:#ddd; cursor: ew-resize; }
  #divider:hover { background:#999; }
  h2,h3,h4 { margin:0 0 12px; color:#333; }
  h2 { font-size:20px; }
  h3 { font-size:18px; color:#0066cc; }
  h4 { font-size:15px; font-weight:600; margin-top:20px; }
  h5 { font-size:14px; font-weight:600; margin:12px 0 8px; }
  #left p { margin: 0 0 14px; line-height: 1.7; text-align:justify; }
  .group { background:#fff; border:1px solid #ddd; border-radius:6px; padding:16px; margin-bottom:16px; }
  .group h4 { margin-top:0; color:#0066cc; }
  .group p { margin:8px 0; font-size:14px; line-height:1.6; }
  .group ol { margin-left:20px; }
  .group ol li { margin:12px 0; font-size:14px; line-height:1.6; position:relative; }
  .group ol li label { display:inline-block; margin-right:8px; cursor: pointer; }
  .group ul { margin-left:20px; }
  .group ul li { margin:8px 0; font-size:14px; line-height:1.8; }
  .question-item, .match-question-item, .q-block { margin:12px 0; font-size:14px; line-height:1.6; }
  .radio-options label, .options label { display:inline-block; margin-right:12px; cursor:pointer; }
  .headings { background:#f9f9f9; padding:12px; margin:12px 0; border-radius:4px; }
  .headings ol { margin-left:20px; }
  .headings li { margin:4px 0; font-size:13px; }
  table { border-collapse: collapse; width:100%; margin:12px 0; }
  th, td { border:1px solid #ddd; padding:6px; text-align:left; font-size:13px; position:relative; }
  th { background:#f5f5f5; font-weight:600; }
  .flag-btn { position:absolute; left:2px; top:50%; transform:translateY(-50%); width:8px; height:8px; border-radius:50%; background:#ddd; cursor:pointer; z-index:10; }
  .flag-btn:hover { background:#999; }
  .flag-btn.active { background:#ff5722; }
  input.blank, input.gap-input, input[type="text"] { border: 1px solid #ccc; border-radius: 4px; padding: 4px 8px; font-size: 14px; width: 160px; margin: 0 5px; font-family: inherit; }
  select { border:1px solid #ccc; border-radius:4px; padding:4px 8px; font-size:14px; font-family:inherit; margin:0 5px; }
  .note-box { border: 1px solid #333; padding: 15px; margin-top: 10px; }
  .note-title { text-align: center; font-weight: bold; font-size: 16px; margin-bottom: 15px; }
  .note-text { line-height: 2; }
  .bottom-bar { display:flex; gap:10px; margin-top:16px; }
  button { padding:10px 20px; border:1px solid #999; border-radius:6px; background:#fff; cursor:pointer; font-size:14px; }
  button:hover { background:#f0f0f0; }
  .btn-primary { background:#0066cc; color:#fff; border-color:#0066cc; }
  .btn-primary:hover { background:#0052a3; }
  .btn-danger { background:#dc3545; color:#fff; border-color:#dc3545; }
  .btn-danger:hover { background:#c82333; }
  .hl { background:#fff59d; cursor:pointer; }
  .hl:hover { background:#ffeb3b; }
  .note { background:#b3d9ff; cursor:pointer; }
  .note:hover { background:#99ccff; }
  #selbar { position:fixed; display:none; z-index:2000; background:#fff; border:1px solid #ddd; border-radius:8px; padding:8px; gap:0; box-shadow:0 2px 8px rgba(0,0,0,0.15); flex-direction:column; min-width:120px; }
  #selbar button { background:#fff; color:#666; border:none; padding:3px 0px; cursor:pointer; font-size:14px; text-align:center; border-radius:4px; }
  #selbar button:hover { background:#f5f5f5; color:#333; }
  .modal { display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.5); z-index:3000; align-items:center; justify-content:center; }
  .modal.active { display:flex; }
  .modal-content { background:#fff; border-radius:8px; padding:24px; max-width:600px; width:90%; max-height:80vh; overflow-y:auto; }
  .modal-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
  .modal-header h2 { font-size: 28px; color: #333; margin: 0; }
  .modal-close { font-size: 32px; cursor: pointer; color: #999; line-height: 1; }
  .modal-close:hover { color: #333; }
  .result-summary { text-align:center; padding:20px; background:#f0f0f0; margin-bottom:16px; border-radius:6px; }
  .result-score { font-size:36px; font-weight:600; color:#0066cc; }
  .result-item { padding:10px; margin:8px 0; border-left:3px solid #ddd; background:#f9f9f9; font-size:13px; }
  .result-item.correct { border-left-color:#28a745; background:#e8f5e9; }
  .result-item.incorrect { border-left-color:#dc3545; background:#ffebee; }
  .wrong-item { background:#fff3e0; padding:16px; margin:8px 0; border-radius:8px; border-left:4px solid #ff9800; display:flex; justify-content:space-between; align-items:start; }
  .wrong-item-content { flex:1; }
  .btn-delete { background:#dc3545; color:white; border:none; padding:6px 12px; border-radius:6px; cursor:pointer; font-size:13px; margin-left:12px; }
  .btn-delete:hover { background:#c82333; }
  .modal-actions { display:flex; gap:10px; margin-bottom:20px; }
</style>'''

SCRIPT_TMPL = r'''<script>
const PAPER_ID=%(paper_id)s;
const ARTICLE_TITLE=%(title_js)s;

let t=0;
const timerEl=document.getElementById('timer');
setInterval(()=>{ t++; timerEl.textContent=String(Math.floor(t/60)).padStart(2,'0')+':'+String(t%%60).padStart(2,'0'); }, 1000);

const divider=document.getElementById('divider'), left=document.getElementById('left'), right=document.getElementById('right');
let dragging=false;
divider.onmousedown=()=>{ dragging=true; document.body.style.cursor='ew-resize'; };
window.onmousemove=(e)=>{ if(!dragging)return; const c=document.querySelector('.shell').getBoundingClientRect(); let x=e.clientX-c.left; x=Math.max(280,Math.min(c.width-280,x)); left.style.flex='0 0 '+x+'px'; right.style.flex='1 1 auto'; };
window.onmouseup=()=>{ dragging=false; document.body.style.cursor=''; };

const selbar=document.getElementById('selbar'), btnHL=document.getElementById('btnHL'), btnUH=document.getElementById('btnUH'), btnNote=document.getElementById('btnNote');
let lastRange=null, currentHlNode=null;
function posSelbar(r){ selbar.style.display='flex'; const t=window.scrollY+r.top-selbar.offsetHeight-8; const l=window.scrollX+r.left+r.width/2-selbar.offsetWidth/2; selbar.style.top=((t>0)?t:(window.scrollY+r.bottom+8))+'px'; selbar.style.left=Math.max(8,l)+'px'; }
function updSel(){ const s=window.getSelection(); if(!s||s.rangeCount===0||s.isCollapsed){ if(!currentHlNode)selbar.style.display='none'; return; } const r=s.getRangeAt(0); lastRange=r.cloneRange(); currentHlNode=null; btnNote.style.display='block'; btnHL.style.display='block'; btnUH.style.display='none'; posSelbar(r.getBoundingClientRect()); }
left.onmouseup=updSel; right.onmouseup=updSel;
document.onselectionchange=()=>{ const s=window.getSelection(); if((!s||s.rangeCount===0||s.isCollapsed)&&!currentHlNode)selbar.style.display='none'; };
document.addEventListener('click',(e)=>{ if(e.target.classList&&(e.target.classList.contains('hl')||e.target.classList.contains('note'))){ currentHlNode=e.target; lastRange=null; btnNote.style.display='none'; btnHL.style.display='none'; btnUH.style.display='block'; posSelbar(e.target.getBoundingClientRect()); const s=window.getSelection(); if(s)s.removeAllRanges(); }}, true);
btnHL.onclick=()=>{ if(currentHlNode||!lastRange||lastRange.collapsed)return; const s=document.createElement('span'); s.className='hl'; try{ lastRange.surroundContents(s); }catch(e){ const w=document.createElement('span'); w.className='hl'; w.appendChild(lastRange.cloneContents()); lastRange.deleteContents(); lastRange.insertNode(w); } selbar.style.display='none'; saveHighlights(); };
btnNote.onclick=()=>{ if(currentHlNode||!lastRange||lastRange.collapsed)return; const s=document.createElement('span'); s.className='note'; try{ lastRange.surroundContents(s); }catch(e){ const w=document.createElement('span'); w.className='note'; w.appendChild(lastRange.cloneContents()); lastRange.deleteContents(); lastRange.insertNode(w); } selbar.style.display='none'; saveHighlights(); };
btnUH.onclick=()=>{ if(currentHlNode){ const p=currentHlNode.parentNode; while(currentHlNode.firstChild)p.insertBefore(currentHlNode.firstChild,currentHlNode); p.removeChild(currentHlNode); p.normalize(); currentHlNode=null; selbar.style.display='none'; saveHighlights(); }else if(lastRange){ const sR=lastRange.getBoundingClientRect(); const w=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT); const tr=[]; while(w.nextNode()){ const n=w.currentNode; if(n.classList&&(n.classList.contains('hl')||n.classList.contains('note'))){ const r=n.getBoundingClientRect(); if(!(r.right<sR.left||r.left>sR.right||r.bottom<sR.top||r.top>sR.bottom))tr.push(n); }} tr.forEach(el=>{ const p=el.parentNode; while(el.firstChild)p.insertBefore(el.firstChild,el); p.removeChild(el); p.normalize(); }); selbar.style.display='none'; saveHighlights(); }};

document.querySelectorAll('.flag-btn').forEach(btn => { btn.onclick = e => { e.stopPropagation(); btn.classList.toggle('active'); saveFlags(); }; });

const answerKey = %(answer_key)s;
let lastResults=[];

function coveredIds(name){
  // combined names drop the "q" on later ids and use "_" or "-":
  // "q8_9"->["q8","q9"], "q12-13-14"->["q12","q13","q14"]
  const parts = name.split(/[-_]/);
  if(!parts.length) return [name];
  const ids = [parts[0]];
  for(let i=1;i<parts.length;i++){ ids.push(/^q/.test(parts[i]) ? parts[i] : 'q'+parts[i]); }
  return ids;
}
function inputForKey(q){
  let el = document.querySelector(`[name="${q}"]`);
  if(el) return el;
  // combined checkbox group (e.g. name="q8_9" covering q8,q9)
  const grp = [...document.querySelectorAll('input[type="checkbox"]')].find(i => coveredIds(i.name).includes(q));
  return grp || null;
}
function gradeOne(q){
  const cA = answerKey[q];
  const el = inputForKey(q);
  let uA = "", iC = false;
  if(el && el.type === 'checkbox'){
    const vals = [...document.querySelectorAll(`input[name="${el.name}"]:checked`)].map(i=>i.value);
    uA = vals.join(', ');
    const lc = vals.map(x=>x.toLowerCase());
    if(Array.isArray(cA)){
      const exp = cA.map(x=>String(x).toLowerCase()).sort();
      const got = [...lc].sort();
      iC = exp.length===got.length && exp.every((v,i)=>v===got[i]);
    } else {
      iC = lc.includes(String(cA).toLowerCase());
    }
  } else if(el && el.type === 'radio'){
    const ch = document.querySelector(`input[name="${q}"]:checked`);
    uA = ch ? ch.value : "";
    const alts = Array.isArray(cA) ? cA : [cA];
    iC = alts.some(a => uA.toLowerCase() === String(a).toLowerCase());
  } else if(el){
    uA = (el.value||'').trim();
    const alts = Array.isArray(cA) ? cA : [cA];
    iC = alts.some(a => uA.toLowerCase() === String(a).toLowerCase());
  }
  const cADisp = Array.isArray(cA) ? cA.join(', ') : cA;
  return { id:q, userAns:uA, correctAns:cADisp, isCorrect:iC };
}

function saveAnswers() {
  const data = {};
  const seen = {};
  Object.keys(answerKey).forEach(q => {
    const el = inputForKey(q);
    if(!el) return;
    if(el.type === 'checkbox'){
      if(seen[el.name]) return; seen[el.name]=1;
      data['cb:'+el.name] = [...document.querySelectorAll(`input[name="${el.name}"]:checked`)].map(i=>i.value);
    } else if(el.type === 'radio'){
      const ch = document.querySelector(`input[name="${q}"]:checked`);
      if(ch) data[q] = ch.value;
    } else {
      data[q] = el.value;
    }
  });
  localStorage.setItem(`${PAPER_ID}_answers`, JSON.stringify(data));
}
function loadAnswers() {
  const data = JSON.parse(localStorage.getItem(`${PAPER_ID}_answers`) || '{}');
  Object.keys(data).forEach(k => {
    const val = data[k];
    if(k.startsWith('cb:')){
      const name = k.slice(3);
      (val||[]).forEach(v => { const cb = document.querySelector(`input[name="${name}"][value="${v}"]`); if(cb) cb.checked = true; });
      return;
    }
    const radio = document.querySelector(`input[name="${k}"][value="${val}"]`);
    if(radio){ radio.checked = true; return; }
    const el = document.querySelector(`[name="${k}"]`);
    if(el && (el.type === 'text' || el.tagName === 'SELECT')) el.value = val;
  });
}
function saveFlags() {
  const flags = [...document.querySelectorAll('.flag-btn.active')].map(b => b.dataset.q);
  localStorage.setItem(`${PAPER_ID}_flags`, JSON.stringify(flags));
}
function loadFlags() {
  const flags = JSON.parse(localStorage.getItem(`${PAPER_ID}_flags`) || '[]');
  flags.forEach(q => document.querySelector(`[data-q="${q}"]`)?.classList.add('active'));
}
function saveHighlights() {
  const highlights = { left: [], right: [] };
  document.querySelectorAll('#left .hl, #left .note').forEach((el, idx) => { highlights.left.push({ type: el.classList.contains('hl') ? 'hl' : 'note', text: el.textContent, index: idx }); });
  document.querySelectorAll('#right .hl, #right .note').forEach((el, idx) => { highlights.right.push({ type: el.classList.contains('hl') ? 'hl' : 'note', text: el.textContent, index: idx }); });
  localStorage.setItem(`${PAPER_ID}_highlights`, JSON.stringify(highlights));
}
function loadHighlights() {
  const data = JSON.parse(localStorage.getItem(`${PAPER_ID}_highlights`) || '{"left":[],"right":[]}');
  const restore = (pane, items) => {
    if(!items || items.length === 0) return;
    items.forEach(item => {
      const walker = document.createTreeWalker(pane, NodeFilter.SHOW_TEXT);
      let node;
      while(node = walker.nextNode()) {
        if(node.textContent.includes(item.text)) {
          const span = document.createElement('span'); span.className = item.type;
          const parent = node.parentNode; const text = node.textContent; const idx = text.indexOf(item.text);
          if(idx >= 0) {
            const before = text.substring(0, idx); const match = text.substring(idx, idx + item.text.length); const after = text.substring(idx + item.text.length);
            parent.insertBefore(document.createTextNode(before), node); span.textContent = match; parent.insertBefore(span, node); parent.insertBefore(document.createTextNode(after), node); parent.removeChild(node); break;
          }
        }
      }
    });
  };
  restore(left, data.left); restore(right, data.right);
}

document.querySelectorAll('input, select').forEach(input => { input.addEventListener('change', saveAnswers); input.addEventListener('input', saveAnswers); });
document.addEventListener('DOMContentLoaded', () => { loadAnswers(); loadFlags(); loadHighlights(); });

function submitAnswers(){
  const res=[]; let cor=0;
  Object.keys(answerKey).forEach(q=>{ const r=gradeOne(q); if(r.isCorrect)cor++; res.push(r); });
  lastResults=res;
  const tot=Object.keys(answerKey).length;
  const pct=((cor/tot)*100).toFixed(1);
  localStorage.setItem(`ielts_score_${PAPER_ID}`, `${cor}/${tot}`);
  document.getElementById('resultContent').innerHTML=`<div class="result-summary"><div class="result-score">${cor} / ${tot}</div><div style="margin-top:8px;font-size:18px;">${pct}%%</div></div>${res.map(r=>`<div class="result-item ${r.isCorrect?'correct':'incorrect'}"><div><strong>${r.id}</strong> ${r.isCorrect?'✓':'✗'}</div><div>你的答案: ${r.userAns||'(未作答)'}</div>${!r.isCorrect?`<div>正确答案: ${r.correctAns}</div>`:''}</div>`).join('')}`;
  document.getElementById('resultModal').classList.add('active');
}
function resetForm(){ document.getElementById('resetModal').classList.add('active'); }
function confirmReset(){
  const tp=document.querySelector('input[name="resetType"]:checked').value;
  document.querySelectorAll('input[type="radio"],input[type="checkbox"]').forEach(i=>i.checked=false);
  document.querySelectorAll('input[type="text"]').forEach(i=>i.value='');
  document.querySelectorAll('select').forEach(i=>i.selectedIndex=0);
  localStorage.removeItem(`${PAPER_ID}_answers`);
  if(tp==='all'){
    document.querySelectorAll('.hl').forEach(el=>{ const p=el.parentNode; while(el.firstChild)p.insertBefore(el.firstChild,el); p.removeChild(el); p.normalize(); });
    document.querySelectorAll('.note').forEach(el=>{ const p=el.parentNode; while(el.firstChild)p.insertBefore(el.firstChild,el); p.removeChild(el); p.normalize(); });
    document.querySelectorAll('.flag-btn').forEach(b => b.classList.remove('active'));
    localStorage.removeItem(`${PAPER_ID}_highlights`);
    localStorage.removeItem(`${PAPER_ID}_flags`);
  }
  closeModal('resetModal');
}
function addWrongToBook(){ const wb=JSON.parse(localStorage.getItem('ielts_wrong_book')||'[]'); const wr=lastResults.filter(r=>!r.isCorrect); wr.forEach(r=>{ const en={paperId:PAPER_ID,title:ARTICLE_TITLE,questionId:r.id,correctAnswer:r.correctAns,myAnswer:r.userAns||'(未作答)',date:new Date().toISOString().split('T')[0]}; const ix=wb.findIndex(i=>i.paperId===en.paperId&&i.questionId===en.questionId); if(ix>=0)wb[ix]=en; else wb.push(en); }); localStorage.setItem('ielts_wrong_book',JSON.stringify(wb)); alert(`已添加 ${wr.length} 道错题`); closeModal('resultModal'); }
function deleteWrongItem(pId,qId){ if(!confirm('确定删除这道错题？'))return; let wb=JSON.parse(localStorage.getItem('ielts_wrong_book')||'[]'); wb=wb.filter(i=>!(i.paperId===pId&&i.questionId===qId)); localStorage.setItem('ielts_wrong_book',JSON.stringify(wb)); openWrongBook(); }
function clearCurrentWrongBook(){ if(!confirm('确定清空本篇所有错题？'))return; let wb=JSON.parse(localStorage.getItem('ielts_wrong_book')||'[]'); wb=wb.filter(i=>i.paperId!==PAPER_ID); localStorage.setItem('ielts_wrong_book',JSON.stringify(wb)); openWrongBook(); }
function openWrongBook(){ const wb=JSON.parse(localStorage.getItem('ielts_wrong_book')||'[]'); const cu=wb.filter(i=>i.paperId===PAPER_ID); const ct=document.getElementById('wrongBookContent'); if(cu.length===0)ct.innerHTML='<div style="text-align:center;padding:40px;color:#666;">暂无错题</div>'; else ct.innerHTML=`<div class="modal-actions"><button class="btn-danger" onclick="clearCurrentWrongBook()" style="width:100%%;">🗑️ 清空本篇错题</button></div>${cu.map(i=>`<div class="wrong-item"><div class="wrong-item-content"><div style="font-weight:600;margin-bottom:8px;">${i.questionId}</div><div style="font-size:13px;color:#666;"><div>✓ 正确: ${i.correctAnswer}</div><div style="color:#d32f2f;">✗ 我的: ${i.myAnswer}</div></div></div><button class="btn-delete" onclick="deleteWrongItem('${i.paperId}','${i.questionId}')">删除</button></div>`).join('')}`; document.getElementById('wrongBookModal').classList.add('active'); }
function closeModal(id){ document.getElementById(id).classList.remove('active'); }
</script>'''

PAGE_TMPL = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>%(title_tag)s</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
%(style)s
</head>
<body>
<div id="timer">00:00</div>

<div class="shell">
  <section class="pane" id="left">

%(passage)s

  </section>

  <div id="divider" title="Drag to resize"></div>

  <section class="pane" id="right">
%(questions)s

    <div class="bottom-bar">
      <button class="btn-primary" onclick="submitAnswers()">提交</button>
      <button onclick="resetForm()">重置</button>
      <button onclick="openWrongBook()">本篇错题</button>
    </div>
  </section>
</div>

<div id="selbar">
  <button id="btnNote">Note</button>
  <button id="btnHL">Highlight</button>
  <button id="btnUH" style="display:none;">Clear Highlight</button>
</div>

<div class="modal" id="resultModal">
  <div class="modal-content">
    <div class="modal-header"><h2>成绩</h2><span class="modal-close" onclick="closeModal('resultModal')">×</span></div>
    <div id="resultContent"></div>
    <button class="btn-primary" style="width:100%%; margin-top:16px;" onclick="addWrongToBook()">加入错题本</button>
  </div>
</div>

<div class="modal" id="wrongBookModal">
  <div class="modal-content">
    <div class="modal-header"><h2>本篇错题</h2><span class="modal-close" onclick="closeModal('wrongBookModal')">×</span></div>
    <div id="wrongBookContent"></div>
  </div>
</div>

<div class="modal" id="resetModal">
  <div class="modal-content">
    <div class="modal-header"><h2>重置练习</h2><span class="modal-close" onclick="closeModal('resetModal')">×</span></div>
    <div style="margin:16px 0;">
      <label style="display:block; margin-bottom:10px;"><input type="radio" name="resetType" value="answers" checked> 只清空答案</label>
      <label style="display:block;"><input type="radio" name="resetType" value="all"> 清空答案和标记</label>
    </div>
    <button class="btn-primary" style="width:100%%;" onclick="confirmReset()">确定</button>
  </div>
</div>

%(script)s
</body>
</html>
'''

def build_page(d):
    meta = d['meta']
    cat = meta.get('category', 'P1')
    title_full = meta.get('title', '')
    title_en = strip_cjk(title_full) or title_full
    pdf = meta.get('pdfFilename', '')
    m = re.match(r'\s*(\d+)\.', pdf)
    idn = int(m.group(1)) if m else None
    freq = meta.get('frequency', 'low')
    paper_id = 'R%d' % idn if idn is not None else 'R_' + re.sub(r'\W', '', d.get('examId',''))
    passage = passage_html(d)
    questions = questions_html(d)
    passage, questions = convert_passage_matching(passage, questions)
    passage, questions = convert_word_bank(passage, questions)
    script = SCRIPT_TMPL % {
        'paper_id': json.dumps(paper_id),
        'title_js': json.dumps(title_en),
        'answer_key': answerkey_js(d.get('answerKey', {})),
    }
    page = PAGE_TMPL % {
        'title_tag': _html.escape('%s – %s' % (cat, title_en)),
        'style': HEAD_STYLE,
        'passage': passage,
        'questions': questions,
        'script': script,
    }
    missing = verify_page(d.get('answerKey', {}), passage + questions)
    return idn, cat, freq, title_en, page, missing

def freq_folder(cat, freq):
    sub = '高频' if freq == 'high' else '次高频'  # 高频 / 次高频
    return '%s%s' % (cat, sub)

def main():
    files = [l.strip() for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
    out_root = sys.argv[2] if len(sys.argv) > 2 else SRC_ROOT
    written = []; flagged = []
    for fn in files:
        path = os.path.join(EXAM_DIR, os.path.basename(fn))
        d = extract_payload(path)
        idn, cat, freq, title_en, page, missing = build_page(d)
        if idn is None:
            print('SKIP (no id):', fn); continue
        if missing:
            flagged.append((idn, os.path.basename(fn), missing))
            print('!! FLAG %3d %s missing inputs for %s' % (idn, os.path.basename(fn), missing))
            continue  # do not ship a page with ungradeable questions
        folder = os.path.join(out_root, freq_folder(cat, freq))
        os.makedirs(folder, exist_ok=True)
        safe = re.sub(r'[\\/:*?"<>|]', '_', title_en)
        dest = os.path.join(folder, '%d. %s - %s.html' % (idn, cat, safe))
        with open(dest, 'w', encoding='utf-8', newline='') as f:
            f.write(page)
        written.append((idn, cat, freq, dest))
        print('WROTE %3d %s %-6s %s' % (idn, cat, freq, os.path.basename(dest)))
    print('\nTotal written:', len(written), '| flagged (not written):', len(flagged))
    for idn, fn, miss in flagged:
        print('   FLAGGED', idn, fn, miss)

if __name__ == '__main__':
    main()
