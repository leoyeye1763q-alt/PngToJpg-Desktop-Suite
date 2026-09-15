'use strict';
const framesByPage=new Map(Array.from(document.querySelectorAll('iframe')).map(f=>[f.dataset.page,f]));
const readyPages=new Set();let currentPage='',requestedPage='conversion',latestState=null,transition=0;
function host(message){window.chrome?.webview?.postMessage(message)}
function deliver(frame,message){frame.contentWindow.postMessage(message,location.origin)}
function mergeState(next){
 if(!latestState)return next;
 return {...latestState,...next,conversion:{...latestState.conversion,...next.conversion},clarity:{...latestState.clarity,...next.clarity},organizer:{...latestState.organizer,...next.organizer},imageLink:{...latestState.imageLink,...next.imageLink},localSearch:{...latestState.localSearch,...next.localSearch},photoshop:{...latestState.photoshop,...next.photoshop},storage:{...latestState.storage,...next.storage},config:{...latestState.config,...next.config}};
}
function navigatePage(page){
 if(!framesByPage.has(page))return;requestedPage=page;if(!readyPages.has(page))return;
 if(currentPage===page)return;
 const incoming=framesByPage.get(page),outgoing=framesByPage.get(currentPage);const token=++transition;
 if(latestState)deliver(incoming,latestState);
 for(const f of framesByPage.values()){f.classList.remove('active','leaving');f.inert=true;f.setAttribute('aria-hidden','true')}
 if(outgoing)outgoing.classList.add('leaving');
 incoming.classList.add('active');incoming.inert=false;incoming.setAttribute('aria-hidden','false');currentPage=page;
 document.querySelector('#loading').hidden=true;document.querySelector('#loading').style.display='none';
 // Keep both opaque page surfaces present during the short transition. No reload or blank frame.
 const content=incoming.contentDocument.querySelector('#desktop-shell>main,#desktop-shell>div');
 if(content&&outgoing&&!matchMedia('(prefers-reduced-motion: reduce)').matches){content.animate([{opacity:.7},{opacity:1}],{duration:120,easing:'ease-out'}).finished.finally(()=>{if(token===transition)outgoing.classList.remove('leaving')})}
 else outgoing?.classList.remove('leaving');
 incoming.contentWindow.focus();host({action:'ready',page});
}
window.navigatePage=navigatePage;
window.addEventListener('message',event=>{
 if(event.origin!==location.origin)return;const frame=Array.from(framesByPage.values()).find(f=>f.contentWindow===event.source);if(!frame)return;
 const m=event.data;
 if(m.action==='ready'){if(latestState)deliver(frame,latestState);return}
 if(m.action==='pageReady'){readyPages.add(frame.dataset.page);if(frame.dataset.page===requestedPage)navigatePage(requestedPage);return}
 if(m.action==='navigate'){navigatePage(m.target);return}
 if(m.action==='drop'&&m.files){window.chrome?.webview?.postMessageWithAdditionalObjects({action:'drop',page:frame.dataset.page,dropTarget:m.dropTarget||'page'},m.files);return}
 host({...m,page:frame.dataset.page});
});
window.chrome?.webview?.addEventListener('message',event=>{
 if(event.data.type==='state'){latestState=mergeState(event.data);for(const [page,frame] of framesByPage)if(page===currentPage||!readyPages.has(page))deliver(frame,latestState)}
 else if(framesByPage.has(currentPage))deliver(framesByPage.get(currentPage),event.data);
});
host({action:'readyShell'});
