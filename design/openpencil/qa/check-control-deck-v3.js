// Read-only geometry check for the six 393x852 OpenPencil artboards.
// Get-Content design/openpencil/qa/check-control-deck-v3.js -Raw |
//   openpencil eval design/openpencil/MIRPG-Control-Deck-V3.fig --stdin
function point(node,root){
 let x=0,y=0,cur=node;
 while(cur&&cur!==root){x+=cur.x||0;y+=cur.y||0;cur=cur.parent;}
 return {x,y,w:node.width||0,h:node.height||0};
}
const errors=[];
const screens=figma.currentPage.children.filter(n=>n.type==='FRAME');
for(const screen of screens){
 const texts=screen.findAll(n=>n.type==='TEXT');
 for(const n of texts){
   const b=point(n,screen);
   if(b.x < -1 || b.y < -1 || b.x+b.w > 394 || b.y+b.h > 853)
     errors.push({screen:screen.name,type:'screen bounds',node:n.name,b});
   if(n.parent&&n.parent!==screen){
     const par=point(n.parent,screen);
     if(b.x+0.5<par.x || b.y+0.5<par.y || b.x+b.w>par.x+par.w+0.5 ||
        b.y+b.h>par.y+par.h+0.5)
       errors.push({screen:screen.name,type:'text clipped by parent',node:n.name,
          parent:n.parent.name,b,parentBounds:par});
   }
 }
 for(let i=0;i<texts.length;i++)for(let j=i+1;j<texts.length;j++){
   const a=point(texts[i],screen),b=point(texts[j],screen);
   const w=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x);
   const h=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
   const overlap=w*h/Math.max(1,Math.min(a.w*a.h,b.w*b.h));
   if(w>7&&h>5&&overlap>0.26)
     errors.push({screen:screen.name,type:'text collision',
       first:texts[i].name,second:texts[j].name,w:Math.round(w),h:Math.round(h),
       overlap:Math.round(overlap*100)+'%'});
 }
}
console.log('ARTBOARDS '+screens.length+'; GEOMETRY_FLAGS '+errors.length);
for(const issue of errors.slice(0,55))console.log(JSON.stringify(issue));
