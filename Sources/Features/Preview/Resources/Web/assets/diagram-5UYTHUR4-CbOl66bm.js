import{t as e}from"./mermaid-parser.core-BvLp8Tih.js";import{E as t,H as n,K as r,M as i,S as a,U as o,b as s,c,d as l,i as u,m as d,x as f}from"./d3-selection-QnkAd7D-.js";import{r as p}from"./chunk-55PJQP7W-SLVo4_4v.js";import{t as m}from"./chunk-353BL4L5-BWZ3Uo_o.js";import{o as h}from"./mermaid.core-BUHSBFh8.js";var g={packet:[]},_=structuredClone(g),v=d.packet,y={pushWord:u(e=>{e.length>0&&_.packet.push(e)},`pushWord`),getPacket:u(()=>_.packet,`getPacket`),getConfig:u(()=>{let e=p({...v,...a().packet});return e.showBits&&(e.paddingY+=10),e},`getConfig`),clear:u(()=>{c(),_=structuredClone(g)},`clear`),setAccTitle:o,getAccTitle:f,setDiagramTitle:r,getDiagramTitle:t,getAccDescription:s,setAccDescription:n},b=1e4,x=u(e=>{m(e,y);let t=-1,n=[],r=1,{bitsPerRow:a}=y.getConfig();for(let{start:o,end:s,bits:c,label:l}of e.blocks){if(o!==void 0&&s!==void 0&&s<o)throw Error(`Packet block ${o} - ${s} is invalid. End must be greater than start.`);if(o??=t+1,o!==t+1)throw Error(`Packet block ${o} - ${s??o} is not contiguous. It should start from ${t+1}.`);if(c===0)throw Error(`Packet block ${o} is invalid. Cannot have a zero bit field.`);for(s??=o+(c??1)-1,c??=s-o+1,t=s,i.debug(`Packet block ${o} - ${t} with label ${l}`);n.length<=a+1&&y.getPacket().length<b;){let[e,t]=S({start:o,end:s,bits:c,label:l},r,a);if(n.push(e),e.end+1===r*a&&(y.pushWord(n),n=[],r++),!t)break;({start:o,end:s,bits:c,label:l}=t)}}y.pushWord(n)},`populate`),S=u((e,t,n)=>{if(e.start===void 0)throw Error(`start should have been set during first phase`);if(e.end===void 0)throw Error(`end should have been set during first phase`);if(e.start>e.end)throw Error(`Block start ${e.start} is greater than block end ${e.end}.`);if(e.end+1<=t*n)return[e,void 0];let r=t*n-1,i=t*n;return[{start:e.start,end:r,label:e.label,bits:r-e.start},{start:i,end:e.end,label:e.label,bits:e.end-i}]},`getNextFittingBlock`),C={parse:u(async t=>{let n=await e(`packet`,t);i.debug(n),x(n)},`parse`)},w=u((e,t,n,r)=>{let i=r.db,a=i.getConfig(),{rowHeight:o,paddingY:s,bitWidth:c,bitsPerRow:u}=a,d=i.getPacket(),f=i.getDiagramTitle(),p=o+s,m=p*(d.length+1)-(f?0:o),g=c*u+2,_=h(t);_.attr(`viewbox`,`0 0 ${g} ${m}`),l(_,m,g,a.useMaxWidth);for(let[e,t]of d.entries())T(_,t,e,a);_.append(`text`).text(f).attr(`x`,g/2).attr(`y`,m-p/2).attr(`dominant-baseline`,`middle`).attr(`text-anchor`,`middle`).attr(`class`,`packetTitle`)},`draw`),T=u((e,t,n,{rowHeight:r,paddingX:i,paddingY:a,bitWidth:o,bitsPerRow:s,showBits:c})=>{let l=e.append(`g`),u=n*(r+a)+a;for(let e of t){let t=e.start%s*o+1,n=(e.end-e.start+1)*o-i;if(l.append(`rect`).attr(`x`,t).attr(`y`,u).attr(`width`,n).attr(`height`,r).attr(`class`,`packetBlock`),l.append(`text`).attr(`x`,t+n/2).attr(`y`,u+r/2).attr(`class`,`packetLabel`).attr(`dominant-baseline`,`middle`).attr(`text-anchor`,`middle`).text(e.label),!c)continue;let a=e.end===e.start,d=u-2;l.append(`text`).attr(`x`,t+(a?n/2:0)).attr(`y`,d).attr(`class`,`packetByte start`).attr(`dominant-baseline`,`auto`).attr(`text-anchor`,a?`middle`:`start`).text(e.start),a||l.append(`text`).attr(`x`,t+n).attr(`y`,d).attr(`class`,`packetByte end`).attr(`dominant-baseline`,`auto`).attr(`text-anchor`,`end`).text(e.end)}},`drawWord`),E={draw:w},D={byteFontSize:`10px`,startByteColor:`black`,endByteColor:`black`,labelColor:`black`,labelFontSize:`12px`,titleColor:`black`,titleFontSize:`14px`,blockStrokeColor:`black`,blockStrokeWidth:`1`,blockFillColor:`#efefef`},O={parser:C,db:y,renderer:E,styles:u(({packet:e}={})=>{let t=p(D,e);return`
	.packetByte {
		font-size: ${t.byteFontSize};
	}
	.packetByte.start {
		fill: ${t.startByteColor};
	}
	.packetByte.end {
		fill: ${t.endByteColor};
	}
	.packetLabel {
		fill: ${t.labelColor};
		font-size: ${t.labelFontSize};
	}
	.packetTitle {
		fill: ${t.titleColor};
		font-size: ${t.titleFontSize};
	}
	.packetBlock {
		stroke: ${t.blockStrokeColor};
		stroke-width: ${t.blockStrokeWidth};
		fill: ${t.blockFillColor};
	}
	`},`styles`)};export{O as diagram};