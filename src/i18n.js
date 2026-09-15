// ===================== Language / i18n =====================
// Covers the app's core chrome (login, license gate, topbar, sidebar quick
// links, settings labels) via [data-i18n] attributes — not every single
// string in the app (provider-supplied channel/movie/series names obviously
// can't be translated, and some deep settings panes aren't tagged yet).
// Add more keys/languages here and tag more elements with data-i18n as
// coverage grows; nothing else needs to change.

const LANGUAGES = [
  { code: 'en', name: 'English' },
  { code: 'ar', name: 'العربية' },
  { code: 'ru', name: 'Русский' },
  { code: 'ur', name: 'اردو' },
  { code: 'es', name: 'Español' }
];

const RTL_LANGS = ['ar', 'ur'];

const I18N = {
  en: {
    'brand.name': 'MY IPTV',
    'login.xtream': 'Xtream Codes',
    'login.m3u': 'M3U URL',
    'login.serverUrl': 'Server URL',
    'login.username': 'Username',
    'login.password': 'Password',
    'login.playlistName': 'Playlist Name',
    'login.m3uUrl': 'M3U URL',
    'login.button': 'Login',
    'license.title': 'Enter your license key to continue',
    'license.seePlans': 'See Plans',
    'license.keyLabel': 'License key',
    'license.verify': 'Verify',
    'plans.title': 'Choose a package',
    'plans.back': 'Back',
    'splash.starting': 'Starting MY IPTV',
    'topbar.live': 'Live TV',
    'topbar.movies': 'Movies',
    'topbar.series': 'Series',
    'topbar.downloads': 'Downloads',
    'topbar.settings': 'Settings',
    'topbar.logout': 'Switch account',
    'sidebar.continue': 'Continue Watching',
    'sidebar.recent': 'Recently Watched',
    'sidebar.favorites': 'Favorites',
    'sidebar.downloads': 'Downloads',
    'sidebar.categories': 'Categories',
    'sidebar.searchCategories': 'Search categories',
    'content.search': 'Search...',
    'settings.language.title': 'Language',
    'settings.language.help': 'Changes the app right away. You can switch back any time.'
  },
  ar: {
    'brand.name': 'MY IPTV',
    'login.xtream': 'Xtream Codes',
    'login.m3u': 'رابط M3U',
    'login.serverUrl': 'رابط الخادم',
    'login.username': 'اسم المستخدم',
    'login.password': 'كلمة المرور',
    'login.playlistName': 'اسم القائمة',
    'login.m3uUrl': 'رابط M3U',
    'login.button': 'تسجيل الدخول',
    'license.title': 'أدخل مفتاح الترخيص للمتابعة',
    'license.seePlans': 'عرض الباقات',
    'license.keyLabel': 'مفتاح الترخيص',
    'license.verify': 'تحقق',
    'plans.title': 'اختر باقة',
    'plans.back': 'رجوع',
    'splash.starting': 'جارٍ تشغيل MY IPTV',
    'topbar.live': 'البث المباشر',
    'topbar.movies': 'أفلام',
    'topbar.series': 'مسلسلات',
    'topbar.downloads': 'التنزيلات',
    'topbar.settings': 'الإعدادات',
    'topbar.logout': 'تبديل الحساب',
    'sidebar.continue': 'متابعة المشاهدة',
    'sidebar.recent': 'شوهد مؤخرًا',
    'sidebar.favorites': 'المفضلة',
    'sidebar.downloads': 'التنزيلات',
    'sidebar.categories': 'الفئات',
    'sidebar.searchCategories': 'ابحث في الفئات',
    'content.search': 'بحث...',
    'settings.language.title': 'اللغة',
    'settings.language.help': 'يغيّر لغة التطبيق فورًا. يمكنك التبديل مرة أخرى في أي وقت.'
  },
  ru: {
    'brand.name': 'MY IPTV',
    'login.xtream': 'Xtream Codes',
    'login.m3u': 'Ссылка M3U',
    'login.serverUrl': 'Адрес сервера',
    'login.username': 'Имя пользователя',
    'login.password': 'Пароль',
    'login.playlistName': 'Название плейлиста',
    'login.m3uUrl': 'Ссылка M3U',
    'login.button': 'Войти',
    'license.title': 'Введите лицензионный ключ, чтобы продолжить',
    'license.seePlans': 'Тарифы',
    'license.keyLabel': 'Лицензионный ключ',
    'license.verify': 'Проверить',
    'plans.title': 'Выберите пакет',
    'plans.back': 'Назад',
    'splash.starting': 'Запуск MY IPTV',
    'topbar.live': 'Прямой эфир',
    'topbar.movies': 'Фильмы',
    'topbar.series': 'Сериалы',
    'topbar.downloads': 'Загрузки',
    'topbar.settings': 'Настройки',
    'topbar.logout': 'Сменить аккаунт',
    'sidebar.continue': 'Продолжить просмотр',
    'sidebar.recent': 'Недавно просмотренные',
    'sidebar.favorites': 'Избранное',
    'sidebar.downloads': 'Загрузки',
    'sidebar.categories': 'Категории',
    'sidebar.searchCategories': 'Поиск категорий',
    'content.search': 'Поиск...',
    'settings.language.title': 'Язык',
    'settings.language.help': 'Меняет язык приложения сразу же. Вы можете переключиться обратно в любое время.'
  },
  ur: {
    'brand.name': 'MY IPTV',
    'login.xtream': 'Xtream Codes',
    'login.m3u': 'M3U لنک',
    'login.serverUrl': 'سرور کا لنک',
    'login.username': 'یوزرنیم',
    'login.password': 'پاسورڈ',
    'login.playlistName': 'پلے لسٹ کا نام',
    'login.m3uUrl': 'M3U لنک',
    'login.button': 'لاگ ان',
    'license.title': 'جاری رکھنے کے لیے اپنی لائسنس کی درج کریں',
    'license.seePlans': 'پیکجز دیکھیں',
    'license.keyLabel': 'لائسنس کی',
    'license.verify': 'تصدیق کریں',
    'plans.title': 'پیکج منتخب کریں',
    'plans.back': 'واپس',
    'splash.starting': 'MY IPTV شروع ہو رہی ہے',
    'topbar.live': 'لائیو ٹی وی',
    'topbar.movies': 'فلمیں',
    'topbar.series': 'سیریز',
    'topbar.downloads': 'ڈاؤن لوڈز',
    'topbar.settings': 'سیٹنگز',
    'topbar.logout': 'اکاؤنٹ تبدیل کریں',
    'sidebar.continue': 'دیکھنا جاری رکھیں',
    'sidebar.recent': 'حال ہی میں دیکھا گیا',
    'sidebar.favorites': 'پسندیدہ',
    'sidebar.downloads': 'ڈاؤن لوڈز',
    'sidebar.categories': 'کیٹیگریز',
    'sidebar.searchCategories': 'کیٹیگریز تلاش کریں',
    'content.search': 'تلاش کریں...',
    'settings.language.title': 'زبان',
    'settings.language.help': 'ایپ کی زبان فوراً بدل جاتی ہے۔ آپ کسی بھی وقت واپس بدل سکتے ہیں۔'
  },
  es: {
    'brand.name': 'MY IPTV',
    'login.xtream': 'Xtream Codes',
    'login.m3u': 'URL M3U',
    'login.serverUrl': 'URL del servidor',
    'login.username': 'Usuario',
    'login.password': 'Contraseña',
    'login.playlistName': 'Nombre de la lista',
    'login.m3uUrl': 'URL M3U',
    'login.button': 'Iniciar sesión',
    'license.title': 'Ingresa tu clave de licencia para continuar',
    'license.seePlans': 'Ver planes',
    'license.keyLabel': 'Clave de licencia',
    'license.verify': 'Verificar',
    'plans.title': 'Elige un paquete',
    'plans.back': 'Atrás',
    'splash.starting': 'Iniciando MY IPTV',
    'topbar.live': 'TV en vivo',
    'topbar.movies': 'Películas',
    'topbar.series': 'Series',
    'topbar.downloads': 'Descargas',
    'topbar.settings': 'Ajustes',
    'topbar.logout': 'Cambiar cuenta',
    'sidebar.continue': 'Continuar viendo',
    'sidebar.recent': 'Visto recientemente',
    'sidebar.favorites': 'Favoritos',
    'sidebar.downloads': 'Descargas',
    'sidebar.categories': 'Categorías',
    'sidebar.searchCategories': 'Buscar categorías',
    'content.search': 'Buscar...',
    'settings.language.title': 'Idioma',
    'settings.language.help': 'Cambia el idioma de la app de inmediato. Puedes volver a cambiarlo cuando quieras.'
  }
};

function t(key) {
  const lang = (window.__currentLang) || 'en';
  return (I18N[lang] && I18N[lang][key]) || I18N.en[key] || key;
}

// Walks every tagged element and applies the current language's text,
// placeholder and title strings; also flips the whole document to RTL for
// Arabic/Urdu. Safe to call again any time the language changes.
function applyLanguage(lang) {
  window.__currentLang = I18N[lang] ? lang : 'en';
  document.documentElement.setAttribute('lang', window.__currentLang);
  document.documentElement.setAttribute('dir', RTL_LANGS.includes(window.__currentLang) ? 'rtl' : 'ltr');

  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.getAttribute('data-i18n'));
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => {
    el.placeholder = t(el.getAttribute('data-i18n-placeholder'));
  });
  document.querySelectorAll('[data-i18n-title]').forEach((el) => {
    el.title = t(el.getAttribute('data-i18n-title'));
  });
}
