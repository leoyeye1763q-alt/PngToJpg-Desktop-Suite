(async()=>{
 // Execute in index.html, using only the isolated SmokeTestWebUi data directory.
 const wait=async(fn,label,ms=15000)=>{const end=Date.now()+ms;while(Date.now()<end){if(fn())return;await new Promise(resolve=>setTimeout(resolve,50))}throw Error(label+' timed out')};
 const assert=(condition,label)=>{if(!condition)throw Error(label)};
 const report=(ok,detail)=>window.chrome.webview.postMessage({action:'uiCheck',page:'settings',ok,detail});
 let ownerWindow,observeState;
 try{
  assert(location.pathname==='/index.html','Nested settings test must run inside the shell');
  navigatePage('clarity');
  await wait(()=>document.querySelector('iframe.active')?.dataset.page==='clarity','Clarity navigation');
  const owner=document.querySelector('iframe.active');ownerWindow=owner.contentWindow;
  const ownerDocument=owner.contentDocument;
  await wait(()=>ownerDocument.documentElement.dataset.ready==='true','Clarity ready');
  const ownerState=()=>ownerWindow.eval('state');
  let stateMessages=0;
  observeState=event=>{if(event.source===window&&event.origin===location.origin&&event.data?.type==='state')stateMessages++};
  ownerWindow.addEventListener('message',observeState);
  const baseline=JSON.stringify(ownerState().config);
  const baselineEndpoint=ownerState().config.Endpoint;
  const open=async()=>{
   assert(!ownerDocument.querySelector('#api-frame'),'Previous settings frame still open');
   ownerDocument.querySelector('[data-action=apiSettings]').click();
   await wait(()=>ownerDocument.querySelector('#api-frame')?.contentDocument?.documentElement.dataset.ready==='true','Nested settings ready');
   const frame=ownerDocument.querySelector('#api-frame');
   assert(frame.contentWindow.parent===ownerWindow&&ownerWindow.parent===window,'Settings is not nested beneath the page and shell');
   return frame;
  };
  const close=async(frame,selector)=>{
   frame.contentDocument.querySelector(selector).click();
   await wait(()=>!ownerDocument.querySelector('#api-frame'),'Settings close');
  };
  const unchangedAfterState=async(previousCount)=>{
   await wait(()=>stateMessages>previousCount,'Fresh host state after validation');
   assert(JSON.stringify(ownerState().config)===baseline,'Validation changed the saved configuration');
  };
  let frame=await open(),modal=frame.contentDocument;
  for(const field of ['Protocol','Endpoint','Model','Prompt','AuthHeader','AuthPrefix','ImageField','TimeoutSeconds','ImageEncoding','ResponseType','ResponsePath','FieldsJson']){
   assert(!!modal.querySelector('[data-field="'+field+'"]'),'API field missing: '+field);
  }
  assert(modal.querySelector('#endpointInput').value===baselineEndpoint,'Nested settings did not load saved fields');
  const status=()=>modal.querySelector('#config-status');
  modal.querySelector('#endpointInput').value='not-a-valid-endpoint';
  let previousCount=stateMessages;
  modal.querySelector('[data-action=validateConfig]').click();
  await wait(()=>status()?.dataset.kind==='error'&&status().textContent.trim().length>0,'Invalid endpoint feedback');
  assert(status().title===status().textContent,'Validation error hover detail missing');
  assert(!modal.querySelector('[data-action=validateConfig]').disabled,'Validation remained disabled after error');
  await unchangedAfterState(previousCount);

  modal.querySelector('#endpointInput').value=baselineEndpoint;
  previousCount=stateMessages;
  modal.querySelector('[data-action=validateConfig]').click();
  await wait(()=>status()?.dataset.kind==='success'&&status().textContent.trim().length>0,'Valid configuration feedback');
  assert(!modal.querySelector('[data-action=saveConfig]').disabled,'Save remained disabled after validation');
  await unchangedAfterState(previousCount);

  modal.querySelector('#modelInput').value='unsaved-nested-ui-test-model';
  const cancel=Array.from(modal.querySelectorAll('[data-action=closeSettings]')).find(button=>button.textContent.trim()==='取消');
  assert(!!cancel,'Cancel button missing');cancel.click();
  await wait(()=>!ownerDocument.querySelector('#api-frame'),'Cancel dismiss');
  frame=await open();modal=frame.contentDocument;
  assert(JSON.stringify(frame.contentWindow.eval('state.config'))===baseline,'Cancel changed saved fields');
  assert(modal.querySelector('#modelInput').value===ownerState().config.Model,'Reopening retained cancelled edits');

  const savedModel='nested-ui-test-model';
  modal.querySelector('#modelInput').value=savedModel;
  modal.querySelector('#apiKeyInput').value='local-nested-ui-test-key';
  modal.querySelector('#clearKeyCheckbox').checked=false;
  modal.querySelector('[data-action=saveConfig]').click();
  await wait(()=>!ownerDocument.querySelector('#api-frame'),'Save dismiss');
  await wait(()=>ownerState().config.Model===savedModel&&ownerState().hasKey,'Saved host configuration');
  assert(/保存/.test(ownerDocument.querySelector('#toast')?.textContent||''),'Save confirmation missing on parent page');
  frame=await open();modal=frame.contentDocument;
  assert(modal.querySelector('#modelInput').value===savedModel,'Saved model was not restored');
  assert(modal.querySelector('#endpointInput').value===baselineEndpoint,'Save changed the endpoint');
  assert(modal.querySelector('#apiKeyInput').value==='************','Saved key mask was not restored');
  assert(modal.querySelector('#apiKeyInput').dataset.saved==='true','Saved key mask was not marked for preservation');
  assert(frame.contentWindow.eval('state.hasKey')===true,'Reopened settings did not report saved credentials');
  modal.querySelector('#modelInput').value='masked-key-preserve-test-model';
  modal.querySelector('[data-action=saveConfig]').click();
  await wait(()=>!ownerDocument.querySelector('#api-frame'),'Masked key save dismiss');
  await wait(()=>ownerState().config.Model==='masked-key-preserve-test-model'&&ownerState().hasKey,'Masked key preservation');
  frame=await open();modal=frame.contentDocument;
  assert(modal.querySelector('#apiKeyInput').value==='************'&&frame.contentWindow.eval('state.hasKey')===true,'Saving the mask replaced or cleared the encrypted key');
  await close(frame,'[data-action=closeSettings][title="关闭"]');

  frame=await open();
  frame.contentDocument.dispatchEvent(new frame.contentWindow.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
  await wait(()=>!ownerDocument.querySelector('#api-frame'),'Escape dismiss');
  assert(owner.isConnected&&owner.contentDocument===ownerDocument,'Settings actions reloaded the parent page');
  navigatePage('conversion');
  await wait(()=>document.querySelector('iframe.active')?.dataset.page==='conversion','Navigation after settings');
  navigatePage('clarity');
  await wait(()=>document.querySelector('iframe.active')===owner,'Return to retained clarity page');
  assert(owner.contentDocument===ownerDocument,'Page switching reloaded clarity after settings');
  report(true,'Nested settings validation, cancel, save, reopen, close and navigation passed');
 }catch(error){report(false,'Nested settings: '+error.message)}
 finally{if(ownerWindow&&observeState)ownerWindow.removeEventListener('message',observeState)}
})();
