import{t as e}from"./mermaid-parser.core-C9RLrMnD.js";import{C as t,E as n,H as r,K as i,M as a,U as o,b as s,c,d as l,i as u,m as d,x as f}from"./d3-selection-DO4mo_Qf.js";import{r as p}from"./d3-scale-DC8_S8q1.js";import{b as m,t as h}from"./d3-shape-Cjytl68A.js";import{f as g,r as _}from"./chunk-55PJQP7W-Dq2jFPax.js";import{t as v}from"./chunk-353BL4L5-B0B7gpWP.js";import{o as y}from"./mermaid.core-BSPLMwZi.js";var b=d.pie,x={sections:new Map,showData:!1,config:b},S=x.sections,C=x.showData,w=structuredClone(b),T={getConfig:u(()=>structuredClone(w),`getConfig`),clear:u(()=>{S=new Map,C=x.showData,c()},`clear`),setDiagramTitle:i,getDiagramTitle:n,setAccTitle:o,getAccTitle:f,setAccDescription:r,getAccDescription:s,addSection:u(({label:e,value:t})=>{S.has(e)||(S.set(e,t),a.debug(`added new section: ${e}, with value: ${t}`))},`addSection`),getSections:u(()=>S,`getSections`),setShowData:u(e=>{C=e},`setShowData`),getShowData:u(()=>C,`getShowData`)},E=u((e,t)=>{v(e,t),t.setShowData(e.showData),e.sections.map(t.addSection)},`populateDb`),D={parse:u(async t=>{let n=await e(`pie`,t);a.debug(n),E(n,T)},`parse`)},O=u(e=>`
  .pieCircle{
    stroke: ${e.pieStrokeColor};
    stroke-width : ${e.pieStrokeWidth};
    opacity : ${e.pieOpacity};
  }
  .pieOuterCircle{
    stroke: ${e.pieOuterStrokeColor};
    stroke-width: ${e.pieOuterStrokeWidth};
    fill: none;
  }
  .pieTitleText {
    text-anchor: middle;
    font-size: ${e.pieTitleTextSize};
    fill: ${e.pieTitleTextColor};
    font-family: ${e.fontFamily};
  }
  .slice {
    font-family: ${e.fontFamily};
    fill: ${e.pieSectionTextColor};
    font-size:${e.pieSectionTextSize};
    // fill: white;
  }
  .legend text {
    fill: ${e.pieLegendTextColor};
    font-family: ${e.fontFamily};
    font-size: ${e.pieLegendTextSize};
  }
`,`getStyles`),k=u(e=>{let t=[...e.entries()].map(e=>({label:e[0],value:e[1]})).sort((e,t)=>t.value-e.value);return m().value(e=>e.value)(t)},`createPieArcs`),A={parser:D,db:T,renderer:{draw:u((e,n,r,i)=>{a.debug(`rendering pie chart
`+e);let o=i.db,s=t(),c=_(o.getConfig(),s.pie),u=y(n),d=u.append(`g`);d.attr(`transform`,`translate(225,225)`);let{themeVariables:f}=s,[m]=g(f.pieOuterStrokeWidth);m??=2;let v=c.textPosition,b=h().innerRadius(0).outerRadius(185),x=h().innerRadius(185*v).outerRadius(185*v);d.append(`circle`).attr(`cx`,0).attr(`cy`,0).attr(`r`,185+m/2).attr(`class`,`pieOuterCircle`);let S=o.getSections(),C=k(S),w=[f.pie1,f.pie2,f.pie3,f.pie4,f.pie5,f.pie6,f.pie7,f.pie8,f.pie9,f.pie10,f.pie11,f.pie12],T=p(w);d.selectAll(`mySlices`).data(C).enter().append(`path`).attr(`d`,b).attr(`fill`,e=>T(e.data.label)).attr(`class`,`pieCircle`);let E=0;S.forEach(e=>{E+=e}),d.selectAll(`mySlices`).data(C).enter().append(`text`).text(e=>(e.data.value/E*100).toFixed(0)+`%`).attr(`transform`,e=>`translate(`+x.centroid(e)+`)`).style(`text-anchor`,`middle`).attr(`class`,`slice`),d.append(`text`).text(o.getDiagramTitle()).attr(`x`,0).attr(`y`,-200).attr(`class`,`pieTitleText`);let D=d.selectAll(`.legend`).data(T.domain()).enter().append(`g`).attr(`class`,`legend`).attr(`transform`,(e,t)=>{let n=22*T.domain().length/2;return`translate(216,`+(t*22-n)+`)`});D.append(`rect`).attr(`width`,18).attr(`height`,18).style(`fill`,T).style(`stroke`,T),D.data(C).append(`text`).attr(`x`,22).attr(`y`,14).text(e=>{let{label:t,value:n}=e.data;return o.getShowData()?`${t} [${n}]`:t});let O=512+Math.max(...D.selectAll(`text`).nodes().map(e=>e?.getBoundingClientRect().width??0));u.attr(`viewBox`,`0 0 ${O} 450`),l(u,450,O,c.useMaxWidth)},`draw`)},styles:O};export{A as diagram};