(function(){
 'use strict';
 const storageKey='pngToJpg.theme';
 const themes=new Set(['classic','cyber','minimal','industrial','mediterranean','retro','liquidCrystal']);
 function normalize(value){return themes.has(value)?value:'classic'}
 function read(){try{return normalize(localStorage.getItem(storageKey))}catch{return'classic'}}
 function syncControls(theme){
  document.querySelectorAll('[data-theme-option]').forEach(control=>{
   const active=control.value===theme;
   control.checked=active;
   control.closest('.theme-card')?.classList.toggle('is-selected',active);
  });
  const status=document.querySelector('#theme-status');
  const selected=document.querySelector(`[data-theme-option][value="${theme}"]`);
  if(status&&selected)status.textContent=`当前使用：${selected.dataset.themeName}`;
 }
 function apply(theme,persist){
  const next=normalize(theme);
  document.documentElement.dataset.theme=next;
  document.documentElement.style.colorScheme=next==='cyber'?'dark':'light';
  if(persist){try{localStorage.setItem(storageKey,next)}catch{}}
  syncControls(next);
  window.dispatchEvent(new CustomEvent('app-theme-change',{detail:{theme:next}}));
  return next;
 }
 window.PngToJpgTheme={apply,read,storageKey,themes:Array.from(themes)};
 apply(read(),false);
 document.addEventListener('DOMContentLoaded',()=>{
  syncControls(read());
  document.querySelectorAll('[data-theme-option]').forEach(control=>control.addEventListener('change',event=>{
   if(event.target.checked)apply(event.target.value,true);
  }));
 });
 window.addEventListener('storage',event=>{if(event.key===storageKey)apply(event.newValue,false)});
})();
