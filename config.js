(function(){
  var host = window.location.hostname;
  var PROD_HOSTS = ['fluxy-erp-v3.vercel.app'];
  var STAGING_HOSTS = []; // preencher explicitamente quando o deploy de staging existir

  var ENV;
  if (host === 'localhost' || host === '127.0.0.1') {
    ENV = 'local';
  } else if (PROD_HOSTS.indexOf(host) !== -1) {
    ENV = 'production';
  } else if (STAGING_HOSTS.indexOf(host) !== -1) {
    ENV = 'staging';
  } else {
    ENV = 'unknown';
  }

  var NAMESPACES = { local: '', production: '', staging: 'fluxy_staging_', unknown: null };
  var NS = NAMESPACES[ENV];

  var SUPABASE_CONFIGS = {
    local: null,
    production: { url: 'https://kufuggixwyjgxhpsvmpe.supabase.co', key: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt1ZnVnZ2l4d3lqZ3hocHN2bXBlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM3OTExNjYsImV4cCI6MjA5OTM2NzE2Nn0.CI0WIyFQSHQzSCXGsTiP2qDzOyeY_GdC6cCSYCaP4SQ' },
    staging: { url: 'https://fwxqucqmqutykesijoxt.supabase.co', key: '<<STAGING_ANON_KEY>>' },
    unknown: null
      };

  window.FLUXY_ENV = ENV;
  window.FLUXY_NS = NS;
  window.FLUXY_BLOCKED = (ENV === 'unknown');
  window.FLUXY_SUPABASE_CONFIG = SUPABASE_CONFIGS[ENV] || null;
  window.FLUXY_SHOW_ENV_BADGE = (ENV === 'staging');

  window.fluxyKey = function(k){
    if (window.FLUXY_BLOCKED) return null;
    var ns = (typeof window.FLUXY_NS === 'string') ? window.FLUXY_NS : '';
          return ns + k;
  };

  if (window.FLUXY_BLOCKED) {
    document.addEventListener('DOMContentLoaded', function(){
            document.body.innerHTML = '';
      document.body.style.cssText = 'display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#111;color:#fff;font-family:sans-serif;text-align:center;padding:20px;';
      document.body.textContent = 'Ambiente Fluxy não reconhecido. A aplicação foi bloqueada por segurança.';
    });
  }
})();
