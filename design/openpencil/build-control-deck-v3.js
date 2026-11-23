/**
 * MIRPG Remote | CONTROL DECK — editable OpenPencil concept
 *
 * Self-contained Figma Plugin API scene creation, no imported raster screenshots.
 * Tested in OpenPencil 0.15.x headless eval. Every frame is editable.
 *
 * 393 × 852 logical Android viewport; six screens; safe-bottom nav; custom
 * cartographic/signal design language. Placeholder preview imagery is illustrative.
 * To rebuild:
 *   Get-Content design/openpencil/build-control-deck-v3.js -Raw |
 *       openpencil eval design/openpencil/MIRPG-Control-Deck-V3.fig --stdin -w
 */
const page=figma.currentPage;
page.name='MIRPG / CONTROL DECK / V3 / 2026-10-12';
for(const n of [...page.children])n.remove();

const K={
  bg:'#0B1418',panel:'#122127',panel2:'#192D32',panel3:'#1B3538',
  muted:'#A6B9BD',ink:'#F3F1EA',mint:'#79E3CA',mintDeep:'#123D37',
  copper:'#DDBA85',line:'#315057',lineSoft:'#233C42',
  blue:'#11394A',blue2:'#1D5B67',teal:'#2F776B',forest:'#20554A',
  light:'#E5F0F1',mid:'#B3CAD0',paper:'#D4E3E4',black:'#091115',
  lavender:'#A7B7DD',sand:'#E9CB9B',warning:'#E5B376',warningDeep:'#382E24',
  gray:'#8FA5A9',darkText:'#3C565C',trail:'#24494D',red:'#FFACA0'
};
function rgb(h){h=h.slice(1);return{r:parseInt(h.slice(0,2),16)/255,g:parseInt(h.slice(2,4),16)/255,b:parseInt(h.slice(4,6),16)/255};}
function paint(c){return[{type:'SOLID',color:rgb(c)}];}
const font={normal:{family:'Inter',style:'Regular'},heavy:{family:'Inter',style:'Bold'}};
await figma.loadFontAsync(font.normal);
await figma.loadFontAsync(font.heavy);
function box(parent,name,x,y,w,h,color,corner=0,stroke=null){
  const n=figma.createFrame();parent.appendChild(n);n.name=name;n.resize(w,h);n.x=x;n.y=y;
  n.fills=color?paint(color):[];n.cornerRadius=corner;n.clipsContent=true;
  if(stroke){n.strokes=paint(stroke);n.strokeWeight=1;}return n;
}
function rect(parent,name,x,y,w,h,color,corner=0,stroke=null){
  const n=figma.createRectangle();parent.appendChild(n);n.name=name;n.resize(w,h);n.x=x;n.y=y;
  n.fills=color?paint(color):[];n.cornerRadius=corner;
  if(stroke){n.strokes=paint(stroke);n.strokeWeight=1;}return n;
}
function orb(parent,name,x,y,d,color,stroke=null){
  const n=figma.createEllipse();parent.appendChild(n);n.name=name;n.resize(d,d);n.x=x;n.y=y;
  n.fills=color?paint(color):[];if(stroke){n.strokes=paint(stroke);n.strokeWeight=1;}return n;
}
function txt(parent,name,value,x,y,w,h,size=14,color=K.ink,bold=false,align='LEFT',track=0){
  const n=figma.createText();parent.appendChild(n);n.name=name;n.fontName=bold?font.heavy:font.normal;
  n.characters=value;n.fontSize=size;n.fills=paint(color);n.textAutoResize='NONE';n.resize(w,h);
  n.x=x;n.y=y;n.textAlignHorizontal=align;n.textAlignVertical='CENTER';
  if(track)n.letterSpacing={value:track,unit:'PIXELS'};
  return n;
}
function rule(parent,name,x,y,w,color=K.lineSoft){return rect(parent,name,x,y,w,1,color);}
function vRule(parent,name,x,y,h,color=K.lineSoft){return rect(parent,name,x,y,1,h,color);}
function status(parent){
  txt(parent,'Phone time','12:49',21,6,78,32,13,K.ink,true);
  orb(parent,'WiFi dot',277,18,5,K.mint);
  txt(parent,'Phone indicators','Wi-Fi 86%',291,7,83,31,11,K.muted,false,'RIGHT');
}
function brand(parent,variant='MIRPG'){
  const mark=box(parent,'MIRPG mono mark',20,51,39,38,K.mintDeep,2,K.line);
  txt(mark,'Angular M','M',4,1,31,35,24,K.mint,true,'CENTER');
  rect(mark,'Logo cut',29,26,6,6,K.copper,1);
  txt(parent,'Brand wordmark',variant,71,49,172,29,18,K.ink,true,'LEFT',.8);
  txt(parent,'Brand descriptor','R E M O T E   /   D E C K',71,76,220,16,9,K.muted,true);
  txt(parent,'Settings action','⋯',341,54,32,33,22,K.muted,true,'CENTER');
}
function section(parent,number,label,y,action=null){
  txt(parent,label+' index',number,18,y,29,21,12,K.copper,true,'LEFT',.2);
  vRule(parent,label+' vertical accent',46,y+4,13,K.line);
  txt(parent,label+' section',label,57,y,223,21,12,K.ink,true,'LEFT',1.3);
  if(action)txt(parent,label+' action',action,267,y,107,21,11,K.mint,true,'RIGHT');
}
function nav(parent,active){
  const dock=box(parent,'Custom four-way command dock',0,765,393,87,K.panel,0);
  rule(dock,'Dock boundary',0,0,393,K.line);
  const labels=['HOME','VIEWS','TOOLS','CODEX'];
  const nums=['01','02','03','04'];
  labels.forEach((name,i)=>{
    const x=18+i*94;
    if(name===active)rect(dock,name+' signal rail',x,0,77,3,K.mint);
    txt(dock,name+' navigation number',nums[i],x,13,77,23,16,name===active?K.mint:K.gray,true,'CENTER');
    txt(dock,name+' navigation label',name,x,40,77,20,11,name===active?K.ink:K.muted,true,'CENTER',.7);
  });
  rect(dock,'Android gesture area',140,80,113,4,K.gray,2);
}
function bottomGesture(parent){rect(parent,'Android gesture bar',140,842,113,4,K.gray,2);}
function signal(parent,x,y,label,accent=K.mint){
  orb(parent,label+' indicator',x,y+7,8,accent);
  const textWidth=Math.min(235,Math.max(105,Math.ceil(label.length*7.7)));
  txt(parent,label+' text',label,x+15,y,textWidth,24,12,accent,true);
}
function topStrip(parent,caption,right){
  txt(parent,caption+' left',caption,20,51,243,25,11,K.mint,true,'LEFT',1.6);
  txt(parent,caption+' right',right,267,51,105,25,11,K.muted,true,'RIGHT');
  rule(parent,'Header hairline',20,83,353,K.line);
}
function button(parent,name,value,x,y,w,h,primary=false){
  const n=box(parent,name,x,y,w,h,primary?K.mint:K.panel2,4,primary?null:K.line);
  if(primary)rect(n,'Signature warm edge',0,0,3,h,K.copper);
  txt(n,name+' button label',value,8,0,w-16,h,13,primary?K.black:K.ink,true,'CENTER');
  return n;
}
function contours(parent,w,h){
  // Signature cropped cartographic rings: calm brand motif, not Material circles.
  [0,1,2].forEach(i=>{
    const d=95+i*46;
    const c=orb(parent,'Signal contour '+i,w-d*.45,-d*.61,d,null,K.line);
    c.strokes=paint(i===1?K.teal:K.line);
    c.strokeWeight=1;
    c.fills=[];
  });
}
function desktopArt(parent,x,y,w,h){
  const p=box(parent,'Conceptual Windows screen thumbnail',x,y,w,h,K.blue,2);
  rect(p,'Blue desktop sheen',0,0,w,h*.58,K.blue2);
  contours(p,w,h);
  const a=box(p,'File Explorer window',w*.08,h*.14,w*.58,h*.73,K.light,3);
  rect(a,'Explorer top bar',0,0,a.width,Math.max(13,h*.12),K.mid,2);
  txt(a,'Window title','EXPLORER',5,2,a.width-10,Math.max(10,h*.11),Math.min(9,h*.08),K.blue,true);
  rect(a,'File pane',0,h*.12,w*.15,a.height-h*.12,K.paper);
  for(let i=0;i<3;i++)rect(a,'File '+i,w*.19,h*.20+i*h*.12,w*.28-i*w*.05,Math.max(3,h*.036),i===0?K.teal:K.mid,2);
  const b=box(p,'Dark code editor',w*.56,h*.33,w*.35,h*.43,K.black,3);
  for(let i=0;i<4;i++){
    const cw=Math.max(7,w*.21-i*8);
    rect(b,'Code glyph '+i,w*.045,9+i*h*.08,cw,Math.max(3,h*.025),i%2?K.lavender:K.mint,2);
  }
  rect(p,'Remote taskbar',0,h-11,w,11,K.black);
  orb(p,'Windows Start control',6,h-8,5,K.mint);
  return p;
}
function gameArt(parent,x,y,w,h,version=0){
  const p=box(parent,'Conceptual Android game thumbnail '+version,x,y,w,h,
    version===1?'#3A5274':K.teal,2);
  rect(p,'Sky tint',0,0,w,h*.48,version===1?'#545E93':'#4B8F89');
  // Rolling treeline and skyline; represented as editable primitive objects.
  rect(p,'Horizon',0,h*.49,w,h*.51,version===1?'#303C60':K.forest);
  [0,1,2,3].forEach(i=>{
    orb(p,'Hillside foliage '+i,(i*51)%w-17,h*.42+(i%2)*14,Math.min(79,w*.44),
      version===1?'#646E9F':'#276E59');
  });
  orb(p,'Avatar head',w*.44,h*.41,Math.min(w*.23,h*.24),K.sand);
  rect(p,'Avatar body',w*.39,h*.61,Math.min(w*.32,55),h*.30,version===1?K.lavender:'#6486B0',8);
  rect(p,'Game foreground',0,h*.89,w,h*.11,version===1?'#3D416B':'#1C433A');
  rect(p,'HUD stripe',9,10,w*.36,4,K.mint,2);
  return p;
}
function miniState(parent,x,y,live=true){
  orb(parent,'State light',x,y+6,7,live?K.mint:K.copper);
  txt(parent,'State copy',live?'LIVE':'STOPPED',x+14,y,78,20,10,live?K.mint:K.copper,true,'LEFT',.4);
}

function phone(name,index){
  const screen=box(page,name,index*429,0,393,852,K.bg,0);
  return screen;
}

// SCREEN 01 | HOME
{
 const s=phone('01 / HOME / Personal command deck',0);
 status(s);brand(s);rule(s,'Brand baseline',20,104,353);
 txt(s,'Home kicker','CONNECTED / JARVIS',20,117,233,24,11,K.mint,true,'LEFT',1.7);
 txt(s,'Hero first line','Your world.',19,144,353,43,33,K.ink,true);
 txt(s,'Hero second line','One connection.',19,184,353,40,32,K.ink,true);
 const connection=box(s,'Network telemetry strip',20,236,353,40,K.mintDeep,2,K.line);
 signal(connection,14,8,'JARVIS IS ONLINE');
 txt(connection,'LAN metrics','LAN  ·  03 ms',228,8,112,24,11,K.mint,true,'RIGHT');
 section(s,'01','WINDOWS',288,'VIEW ALL  →');
 const mon=box(s,'Monitor 1 featured target',20,316,353,190,K.panel,5,K.line);
 desktopArt(mon,9,10,335,124);
 rule(mon,'Monitor meta line',9,145,335,K.line);
 txt(mon,'Monitor title','MONITOR 01',13,154,170,27,15,K.ink,true);
 miniState(mon,197,158,true);
 txt(mon,'Monitor open','OPEN  →',275,156,68,26,12,K.mint,true,'RIGHT');
 section(s,'02','ANDROID',518,'ALL 03  →');
 const first=box(s,'BlueStacks first target',20,545,170,192,K.panel,4,K.line);
 gameArt(first,7,7,156,119);
 txt(first,'Game title','MapleStory Idle',9,132,155,22,14,K.ink,true);
 txt(first,'Game host','BLUESTACKS 01',9,153,145,18,10,K.muted,true,'LEFT',.6);
 miniState(first,9,172,true);
 const second=box(s,'BlueStacks second target',202,545,171,192,K.panel,4,K.line);
 gameArt(second,7,7,157,119,1);
 txt(second,'Game title','MapleStory R',9,132,151,22,14,K.ink,true);
 txt(second,'Game host','BLUESTACKS 02',9,153,153,18,10,K.muted,true,'LEFT',.6);
 miniState(second,9,172,true);
 nav(s,'HOME');
}

// SCREEN 02 | MULTI-VIEW INDEX
{
 const s=phone('02 / VIEWS / Multi-target signal index',1);
 status(s);topStrip(s,'TARGET INDEX','JARVIS  /  05');
 txt(s,'Switcher hero','Switch surface.',20,98,351,43,31,K.ink,true);
 txt(s,'Switcher subhead','All your screens, one continuous session.',20,141,351,23,12,K.muted);
 const tabs=box(s,'Device-type filter line',20,179,353,41,K.panel,1);
 txt(tabs,'All targets filter','ALL 05',10,6,96,27,12,K.mint,true,'CENTER');
 txt(tabs,'Windows filter','PC 02',126,6,95,27,12,K.muted,true,'CENTER');
 txt(tabs,'Android filter','ANDROID 03',233,6,109,27,12,K.muted,true,'CENTER');
 rect(tabs,'Active filter line',20,38,75,3,K.mint);
 section(s,'01','WINDOWS SURFACES',231,'02');
 function targetRow(y,index,title,state,art,active=false){
   const row=box(s,title+' remote target',20,y,353,87,active?K.mintDeep:K.panel,3,active?K.mint:K.line);
   rect(row,'Target numbered accent',0,0,3,87,active?K.mint:K.copper);
   if(art==='desktop')desktopArt(row,11,10,102,66);
   else gameArt(row,11,10,102,66,art==='game-r'?1:0);
   txt(row,'Target serial',index,125,7,40,21,10,K.copper,true);
   txt(row,'Target name',title,125,27,183,26,15,K.ink,true);
   txt(row,'Target subtitle',state,125,57,203,22,11,active?K.mint:K.muted);
   txt(row,'Go to target',active?'●':'↗',318,26,23,38,19,active?K.mint:K.ink,true,'CENTER');
 }
 targetRow(256,'01','Monitor 1','ACTIVE · WINDOWS','desktop',true);
 targetRow(351,'02','Monitor 2','LIVE · WINDOWS','desktop');
 section(s,'02','ANDROID INSTANCES',449,'03');
 targetRow(475,'03','MapleStory Idle','LIVE · BLUESTACKS 01','game');
 targetRow(570,'04','MapleStory R','LIVE · BLUESTACKS 02','game-r');
 const stopped=box(s,'Stopped BlueStacks 3 remote target',20,665,353,87,K.panel,3,K.line);
 rect(stopped,'Stopped indicator',0,0,3,87,K.copper);
 const glyph=box(stopped,'Sleeping guest icon tile',11,10,102,66,K.panel2,2);
 txt(glyph,'Power symbol','◯',30,11,43,43,35,K.copper,true,'CENTER');
 txt(stopped,'Stopped guest index','05',125,7,40,21,10,K.copper,true);
 txt(stopped,'Stopped guest name','BlueStacks 3',125,27,197,26,15,K.ink,true);
 txt(stopped,'Boot action','▶  BOOT INSTANCE',125,57,203,22,11,K.copper,true);
 txt(stopped,'Boot arrow','↗',318,26,23,38,19,K.ink,true,'CENTER');
 rule(s,'Switcher lower rule',20,775,353);
 txt(s,'Switcher footnote','SESSION OPEN · HOLD TO REORDER VIEWS',20,782,353,26,10,K.gray,true,'CENTER',.5);
 bottomGesture(s);
}

// SCREEN 03 | ANDROID GUEST — immersive with reserved navigation rail.
{
 const s=phone('03 / ANDROID / Immersive game with fixed nav lane',2);
 // Game pixels and controls inhabit separate, non-overlapping horizontal regions.
 const feed=box(s,'Reserved portrait game image',0,0,321,852,K.forest);
 rect(feed,'Game atmosphere',0,0,321,290,'#4B9C93');
 [0,1,2,3].forEach(i=>orb(feed,'Distant playable scenery '+i,i*93-39,235+(i%2)*44,160,i%2?'#2F7F69':'#3C917B'));
 rect(feed,'Hills and ground',0,395,321,457,'#214A3C');
 [0,1,2].forEach(i=>orb(feed,'Foreground foliage '+i,235-i*128,398+i*90,172,i%2?'#2D735B':'#2A6751'));
 rect(feed,'Game top information scrim',0,0,321,117,'#153F3C');
 txt(feed,'Guest title','MAPLESTORY IDLE',19,41,211,26,16,K.ink,true,'LEFT',.6);
 txt(feed,'Guest technical channel','GUEST 01  /  LIVE',19,70,227,21,11,K.mint,true,'LEFT',.6);
 rect(feed,'Game level progress background',19,104,176,4,'#24494B',2);
 rect(feed,'Game level progress filled',19,104,117,4,K.mint,2);
 orb(feed,'Avatar hair',108,521,105,'#183B39');
 orb(feed,'Avatar face',121,536,81,K.sand);
 rect(feed,'Avatar jersey',113,604,103,136,'#6386A4',17);
 rect(feed,'Avatar waist accent',115,725,100,8,'#455F7B');
 orb(feed,'Ember',218,589,15,K.copper);
 rect(feed,'Game bottom controls bed',14,757,294,66,'#163D36',5,K.line);
 for(let i=0;i<4;i++){
   const xx=25+i*71;
   const control=box(feed,'Game attack button '+i,xx,769,42,42,i===0?K.copper:K.panel3,21,K.line);
   txt(control,'Game attack index '+i,String(i+1),0,8,42,26,13,i===0?K.black:K.mint,true,'CENTER');
 }
 // A thin drag handle occupies a separate inset within the game feed.
 const switcher=box(s,'Floating target switch handle',0,384,48,107,K.black,0,K.line);
 rect(switcher,'Switcher active edge',0,0,3,107,K.mint);
 txt(switcher,'Switcher count','05',6,18,36,29,16,K.mint,true,'CENTER');
 txt(switcher,'Switcher direction','↗',7,52,35,28,20,K.ink,true,'CENTER');
 // No video lies beneath the Android action lane.
 const rail=box(s,'Dedicated Android system key rail',324,0,69,852,K.black,0);
 vRule(rail,'Rail separator',0,0,852,K.line);
 txt(rail,'Rail edge label','A N D R O I D',4,32,61,33,8,K.muted,true,'CENTER');
 rule(rail,'Rail marker',19,90,31,K.mint);
 function sysAction(y,icon,label){
   const b=box(rail,label+' hit region',8,y,53,67,K.black);
   if(label==='HOME'){
     // Native editable vector house icon; a font glyph may disappear in raster exports.
     rect(b,'House frame',15,17,24,20,null,1,K.ink);
     const roofL=rect(b,'Left roof',12,12,21,2,K.ink,1);roofL.rotation=-39;
     const roofR=rect(b,'Right roof',23,12,21,2,K.ink,1);roofR.rotation=39;
     rect(b,'Door',25,28,5,10,K.ink);
   }else if(label==='RECENTS'){
     for(let i=0;i<4;i++)rect(b,'Recent square '+i,12+(i%2)*16,13+Math.floor(i/2)*16,12,12,null,2,K.ink);
   }else if(label==='TYPE'){
     rect(b,'Keyboard outline',8,14,38,25,null,3,K.ink);
     for(let i=0;i<6;i++)rect(b,'Keyboard key '+i,14+(i%3)*10,21+Math.floor(i/3)*9,6,3,K.ink,1);
   }else{
     txt(b,label+' glyph',icon,3,4,47,36,25,K.ink,true,'CENTER');
   }
   txt(b,label+' caption',label,0,42,53,20,10,K.muted,true,'CENTER');
 }
 sysAction(236,'←','BACK');
 sysAction(327,'⌂','HOME');
 sysAction(418,'▦','RECENTS');
 rule(rail,'Rail section break',13,504,44,K.line);
 sysAction(533,'⌨','TYPE');
 txt(rail,'Video stream metric','LAN',7,715,55,21,10,K.mint,true,'CENTER');
 txt(rail,'Sampled stream FPS','60 FPS',7,739,55,21,10,K.muted,true,'CENTER');
 rect(rail,'Gesture indicator',20,841,30,3,K.gray,2);
}

// SCREEN 04 | WINDOWS — a readable desktop, dedicated tool tray.
{
 const s=phone('04 / WINDOWS / Phone-readable desk mode',3);
 status(s);topStrip(s,'WINDOWS DESKTOP','01 / 02');
 txt(s,'Remote desktop title','Jarvis / Monitor 01',20,91,353,38,23,K.ink,true);
 signal(s,21,132,'DIRECT LAN  ·  03 ms',K.mint);
 const select=box(s,'Display preset selector',20,165,353,40,K.panel,2,K.line);
 txt(select,'Fit option','FIT',5,5,91,28,12,K.muted,true,'CENTER');
 txt(select,'Readable option','READABLE',103,5,140,28,12,K.mint,true,'CENTER');
 txt(select,'Scale option','1:1',265,5,81,28,12,K.muted,true,'CENTER');
 rect(select,'Selected preset indicator',115,37,113,3,K.mint);
 const vp=box(s,'Remote video viewport 2560x1440 (conceptual crop)',20,224,353,420,K.blue,3,K.line);
 rect(vp,'Remote blue task background',0,0,353,420,'#154B62');
 contours(vp,353,420);
 const explorer=box(vp,'Readable File Explorer',35,29,303,312,K.light,4);
 rect(explorer,'File window heading',0,0,303,35,K.mid,4);
 txt(explorer,'Explorer title','File Explorer',12,5,252,25,14,K.blue,true);
 rect(explorer,'Explorer sidebar',0,35,88,277,K.paper);
  for(let i=0;i<4;i++)txt(explorer,'Explorer sidebar entry '+i,
   ['Home','Desktop','Downloads','Projects'][i],12,48+i*48,74,29,11,i===3?K.blue:K.darkText,i===3);
  txt(explorer,'Explorer location','This PC  /  Documents',104,42,198,28,11,K.darkText);
 for(let i=0;i<3;i++){
   rect(explorer,'File icon '+i,113+i*63,91,40,34,i===0?K.blue2:K.mid,3);
   txt(explorer,'Folder label '+i,['Work','Code','Tools'][i],111+i*63,135,46,18,10,K.blue,true,'CENTER');
 }
 rule(explorer,'List separator',108,176,188,'#BDD0D2');
 txt(explorer,'Content header','PROJECTS',108,186,177,27,12,K.blue,true);
 ['MIRPG Remote','Gateway','Marquee'].forEach((name,i)=>{
   rule(explorer,'Content rule '+i,108,215+i*30,188,'#BBCDD0');
   txt(explorer,'Content file '+i,name,117,216+i*30,182,27,11,K.darkText);
 });
 const minimap=box(vp,'Desktop zoom position minimap',237,356,101,44,K.black,2,K.line);
 rect(minimap,'Represented full desktop',8,7,85,30,K.blue2);
 rect(minimap,'Viewport outline',33,10,46,24,null,1,K.mint);
 txt(vp,'Desktop scale marker','2560 × 1440 SOURCE',12,352,203,24,10,K.ink,true);
 // Switch handle sits in viewport margin but doesn't cover File Explorer content.
 const tab=box(s,'Dedicated target switch pull tab',0,448,48,76,K.black,3,K.line);
 rect(tab,'Switcher stripe',0,0,3,76,K.mint);
 txt(tab,'Switcher glyph','05',5,9,37,28,14,K.mint,true,'CENTER');
 txt(tab,'Switcher title','VIEWS',3,41,42,20,10,K.muted,true,'CENTER');
 txt(s,'Input mode hint','TRACKPAD  ·  PINCH ZOOM  ·  TWO-FINGER SCROLL',20,656,353,25,10,K.muted,true);
 const tray=box(s,'Precision-first remote tool tray',20,695,353,87,K.panel,3,K.line);
 [['MOUSE','M'],['KEYBOARD','KB'],['RIGHT CLICK','R'],['SWITCH','05']].forEach(([name,glyph],i)=>{
   const x=6+i*87;
   if(i===0)rect(tray,'Active input selector',x,0,81,3,K.mint);
   txt(tray,'Remote '+name+' glyph',glyph,x,13,81,30,19,i===0?K.mint:K.ink,true,'CENTER');
   txt(tray,'Remote '+name+' label',name,x,46,81,22,9,i===0?K.mint:K.muted,true,'CENTER');
 });
 bottomGesture(s);
}

// SCREEN 05 | CODEX — a real assistant conversation as the first-class surface.
{
 const s=phone('05 / CODEX / Editorial conversation timeline',4);
 status(s);topStrip(s,'WORKSPACE / CODEX','TASK  /  07');
 txt(s,'Codex conversation title','Marquee NextGen',20,97,345,38,26,K.ink,true);
 signal(s,20,140,'RUNNING  ·  2 ACTIONS IN PROGRESS');
 rule(s,'Codex title divider',20,177,353);
 vRule(s,'Task activity timeline',36,212,403,K.line);
 txt(s,'First conversation sequence','01',18,205,36,22,11,K.copper,true);
 const user=box(s,'User message',67,212,306,92,K.panel2,3,K.line);
 rect(user,'Question color edge',0,0,3,92,K.copper);
 txt(user,'User request line 1','Review the current UI.',16,17,274,27,14,K.ink);
 txt(user,'User request line 2','Keep the controls intuitive.',16,48,274,27,14,K.ink);
 txt(s,'Second conversation sequence','02',18,326,36,22,11,K.copper,true);
 txt(s,'Codex speaker','CODEX  /  ACTIVE',67,327,250,24,11,K.mint,true,'LEFT',1.2);
 txt(s,'Codex reply line one','I found the main layout collisions',67,359,299,26,14,K.ink);
 txt(s,'Codex reply line two','and isolated the navigation changes.',67,387,299,26,14,K.ink);
 txt(s,'Codex reply line three','The new preview is ready to inspect.',67,415,299,26,14,K.muted);
 const work=box(s,'Collapsed work timeline',67,467,306,69,K.panel,3,K.line);
 rect(work,'Work event indicator',0,0,3,69,K.mint);
 txt(work,'Work block label','TOOL ACTIVITY  /  04',14,11,253,24,12,K.ink,true);
 txt(work,'Work block status','3 COMPLETE · 1 RUNNING',14,38,250,23,11,K.muted);
 txt(work,'Work event chevron','⌄',270,17,26,33,21,K.mint,true,'CENTER');
 const review=box(s,'Design review preview strip',20,553,353,112,K.mintDeep,3,K.line);
 txt(review,'Review package kicker','REVIEW PACKAGE  /  V3',14,10,273,24,11,K.mint,true,'LEFT',1.1);
 ['HOME','VIEWS','CONTROLS'].forEach((v,i)=>{
   const x=13+i*112;
   rect(review,'Quick screen line '+i,x,46,104,1,K.line);
   txt(review,'Screen shortcut number '+i,String(i+1).padStart(2,'0'),x,51,32,28,19,K.copper,true);
   txt(review,'Screen shortcut label '+i,v,x+30,52,76,26,10,K.ink,true);
 });
 const composer=box(s,'Conversation composer',20,685,353,65,K.panel2,3,K.line);
 txt(composer,'Composer hint','Message Codex...',15,14,235,38,13,K.muted);
 const send=box(composer,'Send action 48px',291,8,48,49,K.mint,3);
 txt(send,'Send chevron','→',5,4,38,39,25,K.black,true,'CENTER');
 nav(s,'CODEX');
}

// SCREEN 06 | RECOVERY — separate the host from one failed video stream.
{
 const s=phone('06 / RECOVERY / Resilient multi-view state',5);
 status(s);brand(s);rule(s,'Brand line',20,104,353);
 txt(s,'Recovery kicker','SIGNAL / RECONNECT',20,129,299,23,11,K.copper,true,'LEFT',1.6);
 txt(s,'Recovery headline','Still connected.',20,157,353,42,30,K.ink,true);
 txt(s,'Recovery subtitle','One video feed needs attention.',20,203,350,25,13,K.muted);
 const host=box(s,'Online host strip',20,245,353,61,K.mintDeep,3,K.line);
 signal(host,14,12,'JARVIS  /  ONLINE');
 txt(host,'Host route','DIRECT LAN  ·  03 ms',30,35,261,19,11,K.muted);
 const failed=box(s,'Specific monitor playback failure',20,323,353,278,K.panel,3,K.line);
 rect(failed,'Warm diagnostic line',0,0,3,278,K.copper);
 txt(failed,'Failed stream eyebrow','MONITOR 01  /  FRAME STALLED',15,12,323,26,11,K.copper,true,'LEFT',.5);
 const scope=box(failed,'Offline preview illustration',15,47,323,73,K.black,2);
 contours(scope,323,73);
 rule(scope,'Oscilloscope base',12,36,297,K.line);
 rect(scope,'Signal pulse left',15,35,112,3,K.mint);
 rect(scope,'Signal pulse right',165,35,140,3,K.gray);
 txt(scope,'Stream discontinuity','×',129,13,37,43,25,K.copper,true,'CENTER');
 txt(failed,'Failure headline','Preview paused',15,131,304,31,20,K.ink,true);
 txt(failed,'Failure detail line 1','Jarvis is online, but this screen',15,165,324,21,12,K.muted);
 txt(failed,'Failure detail line 2','has not delivered a recent frame.',15,187,324,21,12,K.muted);
 button(failed,'Retry stream','RETRY STREAM',15,219,156,48,true);
 button(failed,'Switch view','SWITCH VIEW',181,219,157,48,false);
 section(s,'02','KEEP WORKING',612,'OTHER VIEWS');
 const next=box(s,'Available alternative target',20,639,353,98,K.panel,3,K.line);
 gameArt(next,9,9,103,79);
 txt(next,'Alternative target name','MapleStory Idle',127,14,176,29,15,K.ink,true);
 orb(next,'Alternative state light',127,55,8,K.mint);
 txt(next,'Alternative guest status','BLUESTACKS 01 / LIVE',142,48,186,24,11,K.mint,true);
 txt(next,'Alternative target affordance','↗',314,16,27,35,23,K.mint,true,'CENTER');
 nav(s,'HOME');
}

console.log('MIRPG CONTROL DECK V3: '+page.children.length+' fully editable 393x852 screens');
