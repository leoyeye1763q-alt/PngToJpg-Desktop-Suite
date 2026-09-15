'use strict';
const page=document.body.dataset.page;
let state=null,first=true,selected=-1,lastQueue='',lastLog='',zoom=1,renderedQueueLength=0,lastOrganizerEnabled=null;
const $=s=>document.querySelector(s),$$=s=>Array.from(document.querySelectorAll(s));
function send(action,payload={}){const message={action,page,...payload};if(parent!==window)parent.postMessage(message,location.origin);else window.chrome?.webview?.postMessage(message)}
function toast(message){$('#toast').textContent=message;$('#toast').style.display='block';clearTimeout(window.toastTimer);window.toastTimer=setTimeout(()=>$('#toast').style.display='none',6000)}
function text(id,value){const e=$('#'+id);if(e)e.textContent=value??''}
function set(id,value){const e=$('#'+id);if(e&&document.activeElement!==e){if(e.type==='checkbox')e.checked=!!value;else e.value=value??''}}
function options(){
 if(page==='clarity')return {mode:$('#mode').value,prompt:$('#prompt').value,format:$('#format').value,sameFolder:$('#sameFolder').checked,strength:$('#strength').value,scale:Number($('#scale').value),imageType:$('#imageType').value};
 if(page==='conversion')return {format:$('#format').value,size:Number($('#size').value),width:Number($('#width').value),height:Number($('#height').value),alpha:$('#alpha').checked,sameFolder:$('#sameFolder').checked,openFolder:$('#openFolder').checked,customNameEnabled:$('#customNameEnabled').checked,namePrefix:$('#namePrefix').value,nameSuffix:Math.max(1,Number($('#nameSuffix').value)||1)};
 if(page==='imageLink')return {resize:$('#link-resize').checked,width:Number($('#link-width').value),height:Number($('#link-height').value),keepRatio:$('#link-ratio').checked};
 if(page==='localSearch')return {mode:$('#search-mode').value,query:$('#search-query').value,threshold:Number($('#search-threshold').value)};
 if(page==='photoshop')return {formats:$$('[data-photoshop-format]:checked').map(e=>e.value),jpgQuality:Number($('#photoshop-jpg-quality').value),preserveTransparency:$('#photoshop-preserve-transparency').checked,outputMode:$('[name=photoshop-output]:checked')?.value||'current',outputPath:$('#photoshop-output-path').value};
 return {};
}
function renderImageLink(data){
 if(first){set('link-resize',data.resize);set('link-width',data.width);set('link-height',data.height);set('link-ratio',data.keepRatio);set('link-account',data.accountId);set('link-bucket',data.bucket);set('link-public-url',data.publicBaseUrl);$('#link-access-key').placeholder=data.hasCredentials?'已加密保存；留空继续使用':'R2 Access Key ID';$('#link-secret-key').placeholder=data.hasCredentials?'已加密保存；留空继续使用':'R2 Secret Access Key';first=false}
 text('link-file-name',data.name||'尚未选择图片');text('link-status',data.status);$('#link-progress').value=data.progress;
 $('#link-config-badge').textContent=data.limitReached?'免费额度已用完':(data.hasConfig?'R2 已配置 · 免费保护':'需要 R2 配置');$('#link-drop').classList.toggle('has-file',!!data.name);const usage=$('#link-usage');usage.textContent=`安全额度剩余 ${formatFileSize(data.remainingBytes)} · 本月还可上传 ${data.remainingUploads.toLocaleString()} 张`;usage.classList.toggle('limit-reached',data.limitReached);
 for(const element of $$('[data-link-option]'))element.disabled=data.busy||(element.dataset.linkOption==='size'&&!$('#link-resize').checked);
 $$('[data-action=imageLinkStart]').forEach(e=>e.disabled=data.busy||!data.name||!data.hasConfig||data.limitReached);$$('[data-action=add],[data-action=imageLinkClear],[data-action=imageLinkSaveConfig]').forEach(e=>e.disabled=data.busy);$$('[data-action=imageLinkCancel]').forEach(e=>e.disabled=!data.busy);
 const result=data.result||{};for(const row of $$('[data-result]')){const value=result[row.dataset.result]||'';row.querySelector('input').value=value;row.hidden=!value}
 $('#link-results-empty').hidden=Object.values(result).some(Boolean);document.documentElement.dataset.ready='true';if(!window.pageAnnounced){window.pageAnnounced=true;send('pageReady')}
}
function formatFileSize(bytes){if(bytes>=1073741824)return (bytes/1073741824).toFixed(2)+' GB';if(bytes>=1048576)return (bytes/1048576).toFixed(1)+' MB';if(bytes>=1024)return Math.round(bytes/1024)+' KB';return bytes+' B'}
function updateLocalSearchMode(){if(page!=='localSearch')return;const imageMode=$('#search-mode').value==='image';$('#number-search-fields').hidden=imageMode;$('#image-search-fields').hidden=!imageMode}
function renderLocalSearch(data){
 if(first){set('search-mode',data.mode);set('search-query',data.query);set('search-threshold',String(data.threshold));first=false;updateLocalSearchMode()}
 set('search-mode',data.mode);updateLocalSearchMode();
 set('local-search-root',data.root);text('search-reference-name',data.referenceName||'尚未选择参考图片');const referencePreview=$('#search-reference-preview');if(referencePreview){const preview=data.referencePreview||'';referencePreview.hidden=!preview;if(preview&&referencePreview.src!==preview)referencePreview.src=preview;if(!preview)referencePreview.removeAttribute('src')}text('local-search-status',data.status);const searchProgress=$('#local-search-progress'),searchActions=document.querySelector('.search-actions');searchProgress.style.setProperty('--search-progress',Math.max(0,Math.min(100,data.progress))+'%');searchProgress.classList.toggle('is-running',data.busy);searchProgress.classList.toggle('is-indeterminate',data.busy&&data.progress<1);searchProgress.setAttribute('aria-valuenow',String(data.progress));searchActions.classList.toggle('is-running',data.busy);
 text('local-search-count',data.results.length+' 项');text('local-search-summary',data.busy?`正在扫描，已检查 ${data.scanned} 项`:`已扫描 ${data.scanned} 项`);
 const target=$('#local-search-results');target.replaceChildren();
 if(!data.results.length){const empty=document.createElement('div');empty.className='results-empty';if(data.busy){const running=document.createElement('div');running.className='search-running-state';const spinner=document.createElement('span');spinner.className='search-spinner';const label=document.createElement('strong');label.textContent='正在搜索本地内容';const detail=document.createElement('small');detail.textContent=data.scanned?`已检查 ${data.scanned} 张图片，请稍候…`:'正在读取目录，请稍候…';running.append(spinner,label,detail);empty.append(running)}else empty.textContent='找到的本地文件会显示在这里';target.append(empty)}
 data.results.forEach((result,index)=>{const isDirectory=!!result.IsDirectory;const row=document.createElement('article');row.className='search-result';const visual=result.Preview?document.createElement('img'):document.createElement('div');if(result.Preview){visual.src=result.Preview;visual.alt='';visual.className='result-preview'}else{visual.className='result-placeholder';visual.textContent=result.Kind||'文件'}
  const info=document.createElement('div');info.className='result-info';const name=document.createElement('strong');name.textContent=result.Name;name.title=result.Path;const relative=document.createElement('small');relative.textContent=result.RelativePath;relative.title=result.Path;const meta=document.createElement('div');meta.className='result-meta';const kind=document.createElement('span');kind.textContent=result.Kind;meta.append(kind);if(!isDirectory){const size=document.createElement('span');size.textContent=formatFileSize(result.Size);meta.append(size)}if(data.mode==='image'){const score=document.createElement('span');score.className=result.Exact?'exact':'similar';score.textContent=result.Exact?'完全一致':`${result.Similarity}% 相似`;meta.append(score)}info.append(name,relative,meta);
  const actions=document.createElement('div');actions.className='result-actions';for(const [label,action] of [[isDirectory?'打开文件夹':'打开文件','localSearchOpenFile'],['所在文件夹','localSearchOpenFolder']]){const button=document.createElement('button');button.textContent=label;button.dataset.action=action;button.dataset.index=index;actions.append(button)}row.append(visual,info,actions);target.append(row)});
 $$('[data-action=localSearchStart],[data-action=localSearchBrowseRoot],[data-action=localSearchChooseImage],[data-action=localSearchClear]').forEach(e=>e.disabled=data.busy);$$('[data-action=localSearchCancel]').forEach(e=>e.disabled=!data.busy);$('#search-mode').disabled=data.busy;$('#search-query').disabled=data.busy;$('#search-threshold').disabled=data.busy;
 document.documentElement.dataset.ready='true';if(!window.pageAnnounced){window.pageAnnounced=true;send('pageReady')}
}
function renderPhotoshop(data){
 if(first){set('photoshop-jpg-quality',data.JpgQuality);set('photoshop-preserve-transparency',data.PreserveTransparency);set('photoshop-output-path',data.OutputPath);const output=$(`[name=photoshop-output][value=${data.OutputMode||'current'}]`);if(output)output.checked=true;for(const box of $$('[data-photoshop-format]'))box.checked=(data.Formats||[]).includes(box.value);first=false}
 text('photoshop-version',data.VersionLabel||'尚未检测');text('photoshop-file',data.FileName||'未检测到活动文件');text('photoshop-path',data.PsdPath||'—');text('photoshop-size',data.Width&&data.Height?`${data.Width} × ${data.Height} px`:'—');text('photoshop-status',data.Status||'等待操作');text('photoshop-quality-value',String(data.JpgQuality||10));
 const badge=$('#photoshop-running-badge');badge.textContent=data.Running?'Photoshop 已运行':'Photoshop 未运行';badge.classList.toggle('offline',!data.Running);$('#photoshop-output-path').disabled=data.OutputMode!=='custom'||data.Busy;$$('[data-action=photoshopBrowseOutput]').forEach(e=>e.disabled=data.OutputMode!=='custom'||data.Busy);$$('[data-action=photoshopDetect],[data-action=photoshopRefresh]').forEach(e=>e.disabled=data.Busy);$$('[data-action=photoshopExport]').forEach(e=>e.disabled=data.Busy||!data.Saved||!(data.Formats||[]).length);$$('[data-action=photoshopOpenOutput]').forEach(e=>e.disabled=data.Busy||(!(data.OutputFiles||[]).length&&!data.OutputPath&&!data.PsdPath));for(const input of $$('.photoshop-options input'))input.disabled=data.Busy;
 const results=$('#photoshop-results');results.replaceChildren();if(!(data.OutputFiles||[]).length){const empty=document.createElement('div');empty.className='photoshop-empty';empty.textContent=data.LastError||'导出的本地文件会显示在这里';results.append(empty)}else for(const path of data.OutputFiles){const row=document.createElement('div');row.className='photoshop-result-row';const name=document.createElement('strong');name.textContent=path.split(/[\\/]/).pop();const full=document.createElement('small');full.textContent=path;full.title=path;row.append(name,full);results.append(row)}
 document.documentElement.dataset.ready='true';if(!window.pageAnnounced){window.pageAnnounced=true;send('pageReady')}
}
function renderStorage(data){
 text('storage-total',formatFileSize(data.TotalBytes||0));text('storage-releasable',formatFileSize(data.ReleasableBytes||0));text('storage-file-count',(data.TotalFiles||0).toLocaleString()+' 个文件');text('storage-scan-time','扫描于 '+data.LastScan);text('storage-root',data.DataRoot);
 const target=$('#storage-categories');target.replaceChildren();for(const category of data.Categories||[]){const card=document.createElement('article');card.className='storage-category '+category.Level;card.dataset.category=category.Id;const head=document.createElement('div');head.className='storage-category-head';const copy=document.createElement('div'),name=document.createElement('strong'),desc=document.createElement('small'),badge=document.createElement('span');name.textContent=category.Name;desc.textContent=category.Description;badge.className='storage-recommendation';badge.textContent=category.Level==='safe'?'● '+category.Recommendation:category.Level==='caution'?'● '+category.Recommendation:'● '+category.Recommendation;copy.append(name,desc);head.append(copy,badge);const stats=document.createElement('div');stats.className='storage-category-stats';stats.innerHTML=`<span><b>${formatFileSize(category.Bytes)}</b><small>占用大小</small></span><span><b>${category.FileCount.toLocaleString()}</b><small>文件数量</small></span><span class="storage-path"><b></b><small>目录位置</small></span>`;stats.querySelector('.storage-path b').textContent=(category.Locations||[]).join('；');const actions=document.createElement('div');actions.className='storage-category-actions';for(const [label,action] of [['查看详情','storageDetails'],['打开目录','storageOpen']]){const button=document.createElement('button');button.className='secondary';button.textContent=label;button.dataset.action=action;button.dataset.category=category.Id;if(action==='storageOpen')button.disabled=!category.Exists;actions.append(button)}card.append(head,stats,actions);target.append(card)}
 document.documentElement.dataset.ready='true';if(!window.pageAnnounced){window.pageAnnounced=true;send('pageReady')}
}
function openStorageDetails(categoryId){const category=(state.storage.Categories||[]).find(x=>x.Id===categoryId);if(!category)return;window.storageCategory=category;text('storage-detail-title',category.Name);text('storage-detail-summary',`${category.FileCount.toLocaleString()} 个文件 · ${formatFileSize(category.Bytes)}`);const rows=$('#storage-file-list');rows.replaceChildren();if(!category.Files.length){const empty=document.createElement('p');empty.className='storage-empty';empty.textContent='该分类暂无文件';rows.append(empty)}for(const file of category.Files){const row=document.createElement('label');row.className='storage-file-row';const check=document.createElement('input');check.type='checkbox';check.dataset.storagePath=file.RelativePath;check.dataset.storageSize=file.Size;const info=document.createElement('span'),name=document.createElement('strong'),path=document.createElement('small'),size=document.createElement('b'),time=document.createElement('time');name.textContent=file.Name;path.textContent=file.RelativePath;path.title=file.FullPath;size.textContent=formatFileSize(file.Size);time.textContent=file.CreatedAt;info.append(name,path);row.append(check,info,size,time);rows.append(row)}updateStorageSelection();$('#storage-details-dialog').showModal()}
function updateStorageSelection(){const selected=$$('[data-storage-path]:checked'),bytes=selected.reduce((sum,item)=>sum+Number(item.dataset.storageSize||0),0);text('storage-selected-summary',`已选择 ${selected.length} 个文件 · ${formatFileSize(bytes)}`);const button=$('[data-action=storageDeleteSelected]');if(button)button.disabled=!selected.length}
function updateMode(){if(page!=='clarity')return;const api=$('#mode').value==='API 大模型清晰';$('#prompt-label').hidden=!api;$('#local-options').hidden=api;text('mode-note',api?'开始处理会将所选图片发送到配置的 API 服务商，并可能消耗额度。':'使用本机引擎处理图片。');}
function updateCustomNaming(){if(page!=='conversion')return;const enabled=$('#customNameEnabled').checked;$$('[data-custom-name-control]').forEach(e=>e.disabled=!enabled);const start=Math.max(1,Number($('#nameSuffix').value)||1),prefix=$('#namePrefix').value;text('name-preview',enabled?`输出示例：${prefix}${start}、${prefix}${start+1}…`:'未启用时保留原文件名规则');}
function renderQueue(data){
 const key=JSON.stringify([data.items,selected]);if(key===lastQueue)return;lastQueue=key;
 const q=$('#queue'),previousScrollTop=q.scrollTop,revealNew=data.items.length>renderedQueueLength;renderedQueueLength=data.items.length;q.replaceChildren();
 if(!data.items.length){const empty=document.createElement(page==='conversion'?'div':'tr');empty.className='empty-queue';if(page==='clarity'){const td=document.createElement('td');td.colSpan=3;td.textContent='添加图片开始处理';empty.append(td)}else empty.textContent='添加图片、PDF、Word 或 PPT 开始转换';q.append(empty);return}
 data.items.forEach((item,i)=>{
  const row=document.createElement(page==='conversion'?'div':'tr');row.className='queue-row'+(i===selected?' selected':'');row.tabIndex=0;
  const values=page==='conversion'?[null,item.name,item.dimensions,item.size,item.status]:[null,item.name,item.status];
  values.forEach((value,j)=>{const cell=document.createElement(page==='conversion'?'div':'td');if(j===0){const cb=document.createElement('input');cb.type='checkbox';cb.checked=item.checked;cb.disabled=data.busy;cb.onclick=e=>e.stopPropagation();cb.onchange=()=>send('check',{index:i,value:cb.checked});cell.append(cb)}else{cell.textContent=value;cell.title=page==='clarity'&&j===2&&item.reason?item.reason:value;cell.className=j===1?'file-name':'file-detail'}row.append(cell)});if(page==='clarity'&&item.reason)row.title=item.reason;
  const select=()=>{selected=i;send('select',{index:i});renderQueue(data);text('selection-note',item.name)};row.onclick=select;row.onkeydown=e=>{if(e.key==='Enter')select()};q.append(row);
 });
 if(revealNew)q.lastElementChild?.scrollIntoView({block:'nearest'});else q.scrollTop=previousScrollTop;
}
function renderLog(){if(!state?.changelog)return;const filter=window.logFilter||'';const key=state.changelog+filter;if(lastLog===key)return;lastLog=key;const target=$('#changelog-content');target.replaceChildren();
 const sections=state.changelog.replace(/^# .*$/gm,'').split(/(?=^## )/m).filter(t=>t.trim());let count=0;
 for(const section of sections){if(filter&&!section.includes(filter))continue;const card=document.createElement('article');card.className='release-card';section.split('\n').filter(x=>x.trim()).forEach(line=>{const el=document.createElement(/^#{1,2} /.test(line)?'h2':'p');el.textContent=line.replace(/^#+\s*/,'').replace(/^- /,'• ');card.append(el)});target.append(card);count++}
 if(!count)target.textContent='这个分类暂无更新记录';
}
function renderDesktopHistory(records){
 const target=$('#desktop-history-list');if(!target)return;text('desktop-history-count',records.length+' 条可恢复记录');target.replaceChildren();
 if(!records.length){const empty=document.createElement('div');empty.className='desktop-history-empty';empty.textContent='最近 30 天暂无桌面整理记录';target.append(empty);return}
 records.forEach(record=>{const row=document.createElement('button');row.type='button';row.className='desktop-history-row';row.dataset.action='desktopProductUndo';row.dataset.recordId=record.Id;row.title='点击恢复这一次整理';const summary=document.createElement('span'),title=document.createElement('strong'),meta=document.createElement('small'),path=document.createElement('span'),restore=document.createElement('span'),created=new Date(record.CreatedAt),expires=new Date(record.ExpiresAt),days=Math.max(1,Math.ceil((expires-Date.now())/86400000));title.textContent=`编号 ${record.Code||'未命名'}`;meta.textContent=`${created.toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})} · 移动 ${record.MovedCount} 个文件 · 剩余 ${days} 天`;path.className='desktop-history-path';path.textContent=record.ProjectFolder||'';path.title=record.ProjectFolder||'';restore.className='desktop-history-restore';restore.textContent='恢复这次';summary.append(title,meta);row.append(summary,path,restore);target.append(row)})
}
function receive(s){
 if(s.type==='error'){if(!$('#api-frame'))toast(s.message);return}if(s.type==='storageDeleteResult'){$('#storage-confirm-dialog')?.close();$('#storage-details-dialog')?.close();toast(s.result.Message+(s.result.ReleasedBytes?` 已释放 ${formatFileSize(s.result.ReleasedBytes)}`:''));return}if(s.type==='organizerResult'){toast(s.message);return}if(s.type==='saved'){toast('API 配置已保存');return}if(s.type==='imageLinkSaved'){$('#link-access-key').value='';$('#link-secret-key').value='';$('#link-clear-key').checked=false;$('#r2-config-dialog')?.close();toast('Cloudflare R2 配置已加密保存');return}if(s.type!=='state')return;state=s;
 text('service-status',s.organizer.enabled?'守护服务 · 监控中':'守护服务 · 待启动');
 if(page==='preferences'){document.documentElement.dataset.ready='true';if(!window.pageAnnounced){window.pageAnnounced=true;send('pageReady')}return}
 if(page==='localSearch'){renderLocalSearch(s.localSearch);return}
 if(page==='photoshop'){renderPhotoshop(s.photoshop);return}
 if(page==='storage'){renderStorage(s.storage);return}
 if(page==='organizer'){
  set('organizer-path',s.organizer.path);text('organizer-note','仅监控指定目录：'+s.organizer.path);text('organizer-badge',s.organizer.enabled?'后台监控已启动':'后台监控已停止');text('organizer-status',s.organizer.enabled?'正在监控，等待文件下载稳定':'自动监控未启动');text('organizer-pending','待处理 '+s.organizer.pending+' 项');
  set('organizerOpenSheet',s.organizer.openSheet);set('organizerTargetScreenEnabled',s.organizer.targetScreenEnabled);set('organizerTargetScreen',s.organizer.targetScreen);set('organizerIsland',s.organizer.island);if($('#organizerTargetScreen')){$('#organizerTargetScreen').disabled=!s.organizer.targetScreenEnabled;const second=$('#organizerTargetScreen option[value="2"]');if(second)second.disabled=s.organizer.screenCount<2}
  $$('[data-action=organizerStart]').forEach(e=>{e.disabled=false;e.classList.remove('is-starting');e.classList.toggle('is-active',s.organizer.enabled);e.setAttribute('aria-pressed',String(s.organizer.enabled));e.title=s.organizer.enabled?'自动监控已开启，点击可再次确认状态':'点击启动自动监控';e.querySelector('.organizer-start-play')?.classList.toggle('hidden',s.organizer.enabled);e.querySelector('.organizer-start-check')?.classList.toggle('hidden',!s.organizer.enabled);const label=e.querySelector('.organizer-start-label');if(label)label.textContent=s.organizer.enabled?'监控已开启':'启动自动监控'});$$('[data-action=organizerStop]').forEach(e=>e.disabled=!s.organizer.enabled);$$('[data-action=organizerBrowse]').forEach(e=>e.disabled=s.organizer.enabled);
  if(lastOrganizerEnabled!==null&&lastOrganizerEnabled!==s.organizer.enabled)toast(s.organizer.enabled?'自动监控已开启':'自动监控已停止');lastOrganizerEnabled=s.organizer.enabled;
  set('desktop-organize-scope',s.organizer.desktopScope);renderDesktopHistory(s.organizer.desktopHistory||[]);
  const key=JSON.stringify(s.organizer.log);if(key!==lastLog){lastLog=key;$('#organizer-log').replaceChildren(...s.organizer.log.map(line=>{const p=document.createElement('p');p.textContent=line;return p}));if(!s.organizer.log.length)text('organizer-log','暂无整理记录')}
  $('#spreadsheet-list').replaceChildren(...s.organizer.sheets.map(item=>{const p=document.createElement('p');p.textContent=item;return p}));text('spreadsheet-status',s.organizer.sheetStatus);
 }else if(page==='changelog')renderLog();
 else if(page==='imageLink'){renderImageLink(s.imageLink);return}
 else{
  const data=s[page];if(first){for(const id of ['format','width','height','alpha','sameFolder','openFolder','size','mode','strength','scale','imageType','customNameEnabled','namePrefix','nameSuffix'])if(id in data)set(id,data[id]);if(page==='clarity')set('prompt',s.config.Prompt);first=false;updateMode();updateCustomNaming()}
  set('output-path',data.output);renderQueue(data);text('queue-count',`${data.items.length} 个项目（已勾选 ${data.items.filter(x=>x.checked).length} 项）`);text('pending-count',data.items.length+' 个文件');text('live-status',data.status);if($('#live-status'))$('#live-status').title=data.status;if($('#live-progress'))$('#live-progress').value=data.progress;
  $$('[data-action=start],[data-action=add],[data-action=clear]').forEach(e=>e.disabled=data.busy);$$('[data-action=cancel]').forEach(e=>e.disabled=!data.busy);
  $$('[data-action=checkAll]').forEach(e=>{e.checked=data.items.length>0&&data.items.every(x=>x.checked);e.indeterminate=data.items.some(x=>x.checked)&&!e.checked;e.disabled=data.busy});
  for(const side of ['original','result']){const img=$('#'+side+'-preview');if(img){if(data[side]){if(img.getAttribute('src')!==data[side])img.src=data[side]}else img.removeAttribute('src')}}
  text('model-summary',s.config.Protocol+' / '+s.config.Model);text('api-status','API 配置：'+s.config.Model+' · '+(s.hasKey?'已保存密钥':'未保存密钥'));text('engine-status',(page==='conversion'?'本地转换引擎':'本地图片引擎')+' · '+(data.busy?'处理中':'就绪'));
 }
 document.documentElement.dataset.ready='true';
 if(!window.pageAnnounced){window.pageAnnounced=true;send('pageReady')}
}
function setZoom(value){zoom=Math.max(.25,Math.min(4,value));$$('#original-preview,#result-preview').forEach(e=>{e.style.transform=`scale(${zoom})`});text('zoom-percent',Math.round(zoom*100)+'%');}
document.addEventListener('click',e=>{
 const b=e.target.closest('[data-action]');if(!b||b.disabled||b.type==='checkbox')return;const action=b.dataset.action;
 if(['conversion','clarity','organizer','imageLink','localSearch','photoshop','storage','changelog','settings'].includes(action)){const target=action==='settings'?'preferences':action;if(parent!==window)send('navigate',{target});else location.href='index.html';return}
 if(action==='apiSettings'){if($('#api-frame'))return;const frame=document.createElement('iframe');frame.id='api-frame';frame.title='图片清晰度 API 配置';frame.src='settings.html';document.body.append(frame);return}
 if(action==='spreadsheets'){$('#spreadsheet-dialog').showModal();return}if(action==='dismissSheet'){$('#spreadsheet-dialog').close();return}
 if(action==='desktopOrganizerInfo'){$('#desktop-organizer-info-dialog').showModal();return}if(action==='dismissDesktopOrganizerInfo'){$('#desktop-organizer-info-dialog').close();return}
 if(action==='desktopProductUndo'){send(action,{recordId:b.dataset.recordId});return}
 if(action==='organizerStart'){if(state?.organizer.enabled){toast('自动监控已在运行');return}b.classList.remove('is-active');b.classList.add('is-starting');const label=b.querySelector('.organizer-start-label');if(label)label.textContent='正在启动…';send(action,{options:options()});return}
 if(action==='filterLog'){window.logFilter=b.dataset.filter;renderLog();$$('[data-action=filterLog]').forEach(x=>x.classList.toggle('active-filter',x===b));return}
 if(action==='versionInfo'){toast('当前安装 v3.0.9。本版本通过本机安装更新，未配置在线更新服务。');return}
 if(action==='storageDetails'){openStorageDetails(b.dataset.category);return}
 if(action==='storageOpen'){send(action,{category:b.dataset.category});return}
 if(action==='storageSelectAll'){$$('[data-storage-path]').forEach(x=>x.checked=true);updateStorageSelection();return}
 if(action==='storageDeleteSelected'){const selected=$$('[data-storage-path]:checked'),bytes=selected.reduce((sum,item)=>sum+Number(item.dataset.storageSize||0),0);text('storage-confirm-count',selected.length+' 个文件');text('storage-confirm-size',formatFileSize(bytes));$('#storage-confirm-dialog').showModal();return}
 if(action==='storageConfirmDelete'){const paths=$$('[data-storage-path]:checked').map(x=>x.dataset.storagePath);send('storageDelete',{category:window.storageCategory.Id,paths});b.disabled=true;b.textContent='正在删除…';return}
 if(action==='storageCloseDetails'){$('#storage-details-dialog').close();return}if(action==='storageCancelDelete'){$('#storage-confirm-dialog').close();return}
 if(action==='openR2Config'){$('#r2-config-dialog').showModal();return}
 if(action==='imageLinkSaveConfig'){send(action,{accountId:$('#link-account').value,bucket:$('#link-bucket').value,publicBaseUrl:$('#link-public-url').value,accessKey:$('#link-access-key').value,secretKey:$('#link-secret-key').value,clearCredentials:$('#link-clear-key').checked});return}
 if(action==='imageLinkStart'){send(action,{options:options()});return}
 if(action==='localSearchStart'){send(action,{options:options()});return}
 if(action==='localSearchOpenFile'||action==='localSearchOpenFolder'){send(action,{index:Number(b.dataset.index)});return}
 if(action==='copyLink'){const input=b.closest('[data-result]').querySelector('input');input.select();try{document.execCommand('copy');toast('已复制')}catch{toast('请按 Ctrl+C 复制')}return}
 if(action==='toggleLinkKey'){const show=$('#link-access-key').type==='password';$('#link-access-key').type=show?'text':'password';$('#link-secret-key').type=show?'text':'password';return}
 if(action==='fit'){setZoom(1);$$('.image-viewport').forEach(x=>x.classList.remove('native-size'));return}
 if(action==='zoom'){if(page==='clarity')setZoom(zoom===1?2:1);else{setZoom(1);$$('.image-viewport').forEach(x=>x.classList.toggle('native-size'))}return}
 if(action==='zoomIn'){setZoom(zoom+.25);return}if(action==='zoomOut'){setZoom(zoom-.25);return}
 if(action==='wipe'||action==='sideBySide'){setCompareMode(action);return}
 if(action==='holdOriginal')return;
 if(action==='fullPreview'){$('#compare-container').classList.toggle('expanded-preview');return}
 if(action==='closeFullPreview'){$('#compare-container').classList.remove('expanded-preview');return}
 if(action==='preview'){if(selected<0&&state?.conversion.items.length){selected=0}if(selected>=0)send('select',{index:selected});else toast('请先添加文件');return}
 if(action==='toggleAll'){const data=state[page];send('checkAll',{value:!data.items.every(x=>x.checked)});return}
 send(action,{options:options()});
});
document.addEventListener('change',e=>{
 if(e.target.matches('[data-storage-path]')){updateStorageSelection();return}
 if(e.target.closest('#queue'))return;
 if(e.target.dataset.action==='checkAll'){send('checkAll',{value:e.target.checked});return}
 if(page==='organizer'){if(e.target.id==='desktop-organize-scope'){send('desktopOrganizeScope',{scope:e.target.value});return}if(['organizerOpenSheet','organizerTargetScreenEnabled','organizerTargetScreen','organizerIsland'].includes(e.target.id))send('organizerOptions',{openSheet:$('#organizerOpenSheet').checked,targetScreenEnabled:$('#organizerTargetScreenEnabled').checked,targetScreen:Number($('#organizerTargetScreen').value),island:$('#organizerIsland').checked});return}
 if(page==='imageLink'){for(const element of $$('[data-link-option=size]'))element.disabled=!$('#link-resize').checked;send('imageLinkOptions',{options:options()});return}
 if(page==='localSearch'){updateLocalSearchMode();send('localSearchOptions',{options:options()});return}
 if(page==='photoshop'){const mode=$('[name=photoshop-output]:checked')?.value||'current';$('#photoshop-output-path').disabled=mode!=='custom';$$('[data-action=photoshopBrowseOutput]').forEach(button=>button.disabled=mode!=='custom');text('photoshop-quality-value',$('#photoshop-jpg-quality').value);send('photoshopOptions',{options:options()});return}
 if(['conversion','clarity'].includes(page)){
  if(['width','height'].includes(e.target.id))set('size',4);
  if(e.target.id==='size'){const dims={1:[1650,1650],2:[1464,600],3:[970,600]}[$('#size').value];if(dims){set('width',dims[0]);set('height',dims[1])}}
  if(e.target.id==='namePrefix')set('nameSuffix',({主图:1,副图:2,A:1})[$('#namePrefix').value]||1);
  updateMode();updateCustomNaming();send('options',{options:options()});
 }
});
$('#search')?.addEventListener('input',e=>send('searchText',{value:e.target.value}));
$('#nameSuffix')?.addEventListener('input',updateCustomNaming);
function setCompareMode(next){const viewport=$('#compare-viewport');if(!viewport)return;viewport.classList.toggle('wipe',next==='wipe');for(const action of ['wipe','sideBySide']){const button=$(`[data-action=${action}]`),active=action===next;button?.classList.toggle('compare-mode-active',active);button?.setAttribute('aria-pressed',String(active))}}
const compareViewport=$('#compare-viewport');let compareDragging=false;
function setWipeFromPointer(e){const rect=compareViewport.getBoundingClientRect();if(!rect.width)return;const percent=Math.max(0,Math.min(100,100*(e.clientX-rect.left)/rect.width));compareViewport.style.setProperty('--wipe',percent+'%')}
compareViewport?.addEventListener('pointerdown',e=>{if(!compareViewport.classList.contains('wipe')||e.button!==0)return;e.preventDefault();compareDragging=true;compareViewport.classList.add('dragging');try{compareViewport.setPointerCapture(e.pointerId)}catch{}setWipeFromPointer(e)});
compareViewport?.addEventListener('pointermove',e=>{if(compareDragging)setWipeFromPointer(e)});
function stopCompareDrag(){compareDragging=false;compareViewport?.classList.remove('dragging')}
compareViewport?.addEventListener('pointerup',stopCompareDrag);compareViewport?.addEventListener('pointercancel',stopCompareDrag);compareViewport?.addEventListener('lostpointercapture',stopCompareDrag);
const hold=$('[data-action=holdOriginal]');function setOriginalHeld(active){$('#compare-viewport')?.classList.toggle('original-only',active);hold?.setAttribute('aria-pressed',String(active))}
hold?.addEventListener('pointerdown',e=>{if(e.button!==0)return;e.preventDefault();setOriginalHeld(true)});window.addEventListener('pointerup',()=>setOriginalHeld(false));window.addEventListener('pointercancel',()=>setOriginalHeld(false));hold?.addEventListener('keydown',e=>{if((e.key===' '||e.key==='Enter')&&!e.repeat){e.preventDefault();setOriginalHeld(true)}});hold?.addEventListener('keyup',e=>{if(e.key===' '||e.key==='Enter')setOriginalHeld(false)});hold?.addEventListener('blur',()=>setOriginalHeld(false));
window.addEventListener('message',e=>{if(e.origin!==location.origin)return;if(e.source===parent&&parent!==window){receive(e.data);$('#api-frame')?.contentWindow.postMessage(e.data,location.origin);return}if(e.source!==$('#api-frame')?.contentWindow)return;if(e.data.action==='dismiss'){$('#api-frame').remove();return}if(e.data.action==='ready'){if(state)e.source.postMessage(state,location.origin);return}send(e.data.action,{config:e.data.config})});
window.chrome?.webview?.addEventListener('message',e=>{receive(e.data);$('#api-frame')?.contentWindow.postMessage(e.data,location.origin)});
function hasDraggedFiles(e){return Array.from(e.dataTransfer?.types||[]).includes('Files')}
function clearDropIndicator(){$('#queue-card')?.classList.remove('drop-active');$('#local-search-drop')?.classList.remove('drop-active')}
window.addEventListener('dragover',e=>{if(!hasDraggedFiles(e))return;e.preventDefault();e.stopPropagation();e.dataTransfer.dropEffect='copy';$('#queue-card')?.classList.add('drop-active');$('#local-search-drop')?.classList.add('drop-active')},true);
window.addEventListener('dragleave',e=>{if(!e.relatedTarget)clearDropIndicator()},true);
window.addEventListener('drop',e=>{if(!hasDraggedFiles(e))return;e.preventDefault();e.stopPropagation();clearDropIndicator();const files=Array.from(e.dataTransfer.files);if(!files.length)return;const dropTarget=page==='organizer'&&$('#spreadsheet-dialog')?.open?'spreadsheets':'page';if(parent!==window)send('drop',{files,dropTarget});else if(window.chrome?.webview?.postMessageWithAdditionalObjects)chrome.webview.postMessageWithAdditionalObjects({action:'drop',page,dropTarget},files);else toast('请通过添加按钮选择本地文件')},true);
window.addEventListener('error',e=>{document.documentElement.dataset.ready='true';toast('界面错误：'+e.message);send('uiError',{message:e.message})});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){$('#compare-container')?.classList.remove('expanded-preview');$('#api-frame')?.remove()}});
send('ready');








