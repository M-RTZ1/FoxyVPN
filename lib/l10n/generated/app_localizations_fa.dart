// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get navHome => 'خانه';

  @override
  String get navServers => 'سرورها';

  @override
  String get navSettings => 'تنظیمات';

  @override
  String get navLogs => 'گزارش‌ها';

  @override
  String get actionCancel => 'انصراف';

  @override
  String get actionSignOut => 'خروج از حساب';

  @override
  String get signOutDialogTitle => 'خروج از حساب؟';

  @override
  String get signOutDialogBody =>
      'اتصال قطع می‌شود و نشست Firefox Account شما از این دستگاه حذف می‌شود.';

  @override
  String get statusDisconnected => 'قطع است';

  @override
  String get statusConnecting => 'در حال اتصال…';

  @override
  String get statusWaitingForNetwork => 'در انتظار شبکه…';

  @override
  String get statusReconnecting => 'اتصال دوباره…';

  @override
  String statusTunnelActive(String country) {
    return 'تونل • $country';
  }

  @override
  String statusSystemProxyActive(String address) {
    return 'پراکسی سیستم • $address';
  }

  @override
  String statusProxyActive(String address) {
    return 'پراکسی • $address';
  }

  @override
  String get homeEstablishingTunnel => 'در حال برقراری اتصال…';

  @override
  String get homeTrafficUnprotected => 'ترافیک شما محافظت نمی‌شود';

  @override
  String homeLocalProxy(String address) {
    return 'پراکسی محلی روی $address';
  }

  @override
  String get statDownload => 'دانلود';

  @override
  String get statUpload => 'آپلود';

  @override
  String get quotaPending =>
      'اطلاعات سهمیه پس از برقراری اتصال تونل نمایش داده می‌شود.';

  @override
  String quotaLeftOf(String remaining, String max) {
    return '$remaining باقی‌مانده از $max';
  }

  @override
  String quotaLeft(String remaining) {
    return '$remaining باقی‌مانده';
  }

  @override
  String get autoSelectedLocation => 'موقعیت خودکار';

  @override
  String homeSplitTunnelRules(int count) {
    return '$count قانون split tunneling آماده است';
  }

  @override
  String homeSplitTunnelBypassed(int count) {
    return '$count اتصال بدون VPN (مستقیم) برقرار شد';
  }

  @override
  String exitLocation(String location) {
    return 'موقعیت خروج: $location';
  }

  @override
  String get serverCardRecommended => 'پیشنهادی (خودکار)';

  @override
  String get serverCardPickLocation => 'از بخش سرورها یک موقعیت انتخاب کنید';

  @override
  String get loginSubtitle => 'با Firefox Account خود وارد شوید';

  @override
  String get loginTwoFactorSubtitle =>
      'کد تأیید ارسال‌شده به ایمیل خود را وارد کنید';

  @override
  String get loginEmailLabel => 'ایمیل';

  @override
  String get loginPasswordLabel => 'رمز عبور';

  @override
  String get loginCodeLabel => 'کد تأیید';

  @override
  String get loginEmailInvalid => 'یک نشانی ایمیل معتبر وارد کنید';

  @override
  String get loginPasswordRequired => 'رمز عبور خود را وارد کنید';

  @override
  String get loginSignIn => 'ورود';

  @override
  String get loginVerify => 'تأیید';

  @override
  String get loginBackToSignIn => 'بازگشت به صفحه‌ی ورود';

  @override
  String get serversTitle => 'موقعیت‌ها';

  @override
  String get serversReload => 'بارگذاری دوباره';

  @override
  String get serversRecommended => 'پیشنهادی برای شما';

  @override
  String get serversRecommendedSubtitle =>
      'به‌صورت خودکار از سریع‌ترین کشور موجود انتخاب می‌شود';

  @override
  String get serversAutoChosen => 'موقعیت به‌صورت خودکار انتخاب خواهد شد';

  @override
  String serversLocationSet(String country, String authority) {
    return 'موقعیت تنظیم شد: $country ($authority)';
  }

  @override
  String serversLoadFailed(String error) {
    return 'فهرست سرورها بارگذاری نشد: $error';
  }

  @override
  String get serversNoneAvailable => 'در حال حاضر هیچ موقعیتی در دسترس نیست.';

  @override
  String get serversBundledSnapshot =>
      'فهرست زندهٔ سرورها در دسترس نبود؛ نسخهٔ همراه برنامه نمایش داده می‌شود و ممکن است قدیمی باشد.';

  @override
  String get serversNoServers => 'هیچ سرور قابل‌استفاده‌ای در این کشور نیست.';

  @override
  String serversCityCount(int count) {
    return '$count شهر';
  }

  @override
  String serversPort(int port) {
    return 'پورت $port';
  }

  @override
  String get serversPinging => 'در حال پینگ…';

  @override
  String get serversPingUnavailable => 'پینگ در دسترس نیست';

  @override
  String serversPingResult(int ms) {
    return '$ms میلی‌ثانیه';
  }

  @override
  String get serversTryAgain => 'تلاش دوباره';

  @override
  String get sectionAppearance => 'ظاهر';

  @override
  String get sectionLanguage => 'زبان';

  @override
  String get sectionConnection => 'اتصال';

  @override
  String get sectionConnectionMode => 'حالت اتصال';

  @override
  String get connectionModeProxy => 'پراکسی';

  @override
  String get connectionModeSystemProxy => 'پراکسی سیستم';

  @override
  String get connectionModeTunnel => 'تونل';

  @override
  String get connectionModeProxyDesc =>
      'فقط برنامه‌هایی که به‌صورت دستی پراکسی محلی (127.0.0.1:21080) را تنظیم کرده‌اند از VPN عبور می‌کنند.';

  @override
  String get connectionModeSystemProxyDesc =>
      'پراکسی سیستم ویندوز به‌صورت خودکار تنظیم می‌شود تا اکثر برنامه‌ها (مرورگرها و غیره) بدون پیکربندی دستی از VPN استفاده کنند.';

  @override
  String get connectionModeTunnelDesc =>
      'VPN کامل سیستمی: تمام ترافیک از طریق آداپتور Wintun از تونل عبور می‌کند. نیاز به اجرا به‌عنوان Administrator دارد.';

  @override
  String get sectionLocalProxy => 'پراکسی محلی (SOCKS5 + HTTP)';

  @override
  String get sectionUpstreamProxy => 'عبور از پراکسی بالادستی';

  @override
  String get sectionTunnelEngine => 'موتور تونل';

  @override
  String get sectionAbout => 'درباره';

  @override
  String get themeAuto => 'خودکار';

  @override
  String get themeLight => 'روشن';

  @override
  String get themeDark => 'تیره';

  @override
  String get languageSystem => 'خودکار';

  @override
  String get languageEnglish => 'English';

  @override
  String get languagePersian => 'فارسی';

  @override
  String get exitCheckTitle => 'بررسی کشور خروج';

  @override
  String get exitCheckSubtitle =>
      'پس از اتصال، کشور خروج را بررسی و در صورت عدم تطابق هشدار ثبت می‌کند';

  @override
  String get dohTitle => 'resolver برای DNS-over-HTTPS (نام edge)';

  @override
  String get customDnsTitle => 'سرور DNS سفارشی برای تونل';

  @override
  String get customDnsSubtitle =>
      'وقتی روشن است، این resolver به‌جای fake-DNS داخلی به برنامه‌ها داده می‌شود';

  @override
  String get customDnsLabel => 'سرور DNS سفارشی (IPv4)';

  @override
  String get customDnsHelper => 'مثلاً 1.1.1.1';

  @override
  String get errorInvalidDns => 'نشانی DNS معتبر نیست';

  @override
  String get pinnedEdgeLabel => 'آدرس ثابت edge (اختیاری)';

  @override
  String get pinnedEdgeHelper =>
      'همه‌ی اتصال‌ها را به dial کردن این IP از edge فستلی مجبور می‌کند';

  @override
  String get errorInvalidHostOrIp => 'hostname یا IP معتبر نیست';

  @override
  String get bindAddressLabel => 'نشانی bind';

  @override
  String get localProxyApplyHint =>
      'در حالت فقط‌پراکسی بلافاصله اعمال می‌شود؛ در حالت تمام‌VPN از اتصال بعدی';

  @override
  String get errorInvalidIp => 'نشانی IP معتبر نیست';

  @override
  String get portLabel => 'پورت';

  @override
  String get errorInvalidPort => 'شماره‌ی پورت معتبر نیست';

  @override
  String get sectionSplitTunnel => 'تونل تفکیکی (Split tunneling)';

  @override
  String get splitTunnelTitle => 'تونل تفکیکی بر پایه‌ی مقصد';

  @override
  String get splitTunnelSubtitle =>
      'دامنه‌ها و بازه‌های آدرس دلخواه را بدون VPN ارسال کنید. تفکیک بر پایه‌ی برنامه ممکن نیست، چون tunnel نمی‌فهمد کدام برنامه اتصال را باز کرده است.';

  @override
  String get splitTunnelDefaultTitle => 'ترافیکی که به هیچ قاعده‌ای نمی‌خورد';

  @override
  String get splitTunnelActionTunnel => 'از VPN';

  @override
  String get splitTunnelActionDirect => 'بدون VPN';

  @override
  String get splitTunnelActionLabel =>
      'عمل قاعده‌ای که افزودن آن را شروع کرده‌اید';

  @override
  String get splitTunnelPatternLabel => 'دامنه یا نشانی';

  @override
  String get splitTunnelPatternHelper =>
      'مثلاً .ir یا example.com یا 203.0.113.7 یا 192.168.0.0/16';

  @override
  String get splitTunnelAddRule => 'افزودن قاعده';

  @override
  String get splitTunnelInvalidPattern => 'دامنه یا نشانی قابل‌استفاده نیست';

  @override
  String get splitTunnelNoRules =>
      'هنوز قاعده‌ای نیست. یک TLD مثل .ir، یک دامنه یا یک بازه‌ی IPv4 اضافه کنید.';

  @override
  String get splitTunnelDeleteRule => 'حذف این قاعده';

  @override
  String get splitTunnelApplyHint =>
      'قاعده‌ها روی اتصال‌های تازه اعمال می‌شوند. فقط IPv4: تونل مسیر IPv6 را ندارد، پس ترافیک IPv6 از قبل بدون VPN می‌رود.';

  @override
  String get upstreamTitle => 'استفاده از پراکسی بالادستی';

  @override
  String get upstreamSubtitle =>
      'همه‌ی درخواست‌ها (ورود، Guardian، فهرست سرور و اتصال به edge) از یک پراکسی SOCKS5 یا HTTP عبور می‌کنند؛ نام‌کاربری و رمز فقط برای اتصال به edge اعمال می‌شود';

  @override
  String get proxyTypeLabel => 'نوع پراکسی';

  @override
  String get proxyTypeHttp => 'HTTP (CONNECT)';

  @override
  String get proxyHostLabel => 'سرور پراکسی';

  @override
  String get proxyPortLabel => 'پورت پراکسی';

  @override
  String get copyFromSystemProxy => 'کپی از پراکسی سیستم ویندوز';

  @override
  String get noSystemProxyConfigured =>
      'ویندوز هیچ پراکسی سیستمی تنظیم‌شده‌ای ندارد';

  @override
  String unparsableSystemProxy(String value) {
    return 'تنظیم پراکسی ویندوز قابل‌فهم نبود: $value';
  }

  @override
  String get proxyUsernameLabel => 'نام‌کاربری پراکسی (اختیاری)';

  @override
  String get proxyPasswordLabel => 'رمز پراکسی (اختیاری)';

  @override
  String get saveCredentials => 'ذخیره‌ی اعتبارنامه‌ها';

  @override
  String get credentialsSaved => 'اعتبارنامه‌ی پراکسی ذخیره شد';

  @override
  String get tunnelPathLabel => 'مسیر hev-socks5-tunnel.exe';

  @override
  String get tunnelPathHelper =>
      'اگر خالی بگذارید، کنار فایل اجرایی برنامه (یا در پوشه‌ی bin\\) جست‌وجو می‌شود. برای حالت تمام‌VPN لازم است؛ حالت پراکسی به آن نیازی ندارد.';

  @override
  String get aboutBody =>
      'FoxyVPN برای ویندوز • ترافیک روی استریم‌های HTTP/2 CONNECT از edge های فستلی عبور می‌کند و از سهمیه‌ی Firefox VPN شما استفاده می‌کند (ماهی ۵۰ گیگابایت رایگان).\n\nحالت تمام‌VPN یک adapter وینتون می‌سازد و برنامه باید با دسترسی ادمین اجرا شود.';

  @override
  String get aboutSource => 'سورس: github.com/M-RTZ1/FoxyVPN';

  @override
  String get copySourceUrl => 'کپی آدرس سورس پروژه';

  @override
  String get sourceUrlCopied => 'آدرس سورس کپی شد';

  @override
  String get logsTitle => 'گزارش‌ها';

  @override
  String get logsShowOldestFirst => 'نمایش قدیمی‌ترها ابتدا';

  @override
  String get logsShowNewestFirst => 'نمایش تازه‌ترها ابتدا';

  @override
  String get logsCopyAll => 'کپی همه';

  @override
  String get logsExportToFile => 'خروجی فایل';

  @override
  String get logsClear => 'پاک کردن';

  @override
  String get logsEmpty => 'هنوز هیچ گزارشی ثبت نشده است.';

  @override
  String get logsCopiedToClipboard => 'گزارش‌ها در کلیپ‌بورد کپی شد';

  @override
  String logsExported(String path) {
    return 'گزارش در $path ذخیره شد';
  }

  @override
  String logsExportFailed(String error) {
    return 'خطا در خروجی گرفتن: $error';
  }

  @override
  String aboutVersion(String version) {
    return 'نسخه $version';
  }

  @override
  String get updateCheckAction => 'بررسی به‌روزرسان';

  @override
  String get updateChecking => 'در حال بررسی GitHub…';

  @override
  String updateUpToDate(String version) {
    return 'جدیدترین نشره را دارید ($version)';
  }

  @override
  String get updateNonePublished => 'هنوز هیچ نشره‌ای در GitHub منتشر نشده است';

  @override
  String updateFailed(String error) {
    return 'بررسی به‌روزرسان ناموفق بود: $error';
  }

  @override
  String updateAvailableTitle(String latest) {
    return 'FoxyVPN $latest دسترس است';
  }

  @override
  String updateAvailableBody(String current) {
    return 'اکنون نسخه $current را دارید. برای گرفتن نسخه‌ی جدید، release آن را در GitHub باز کنید.';
  }

  @override
  String updateActionDownload(String asset) {
    return 'دریافت $asset';
  }

  @override
  String get updateActionOpenRelease => 'باز کردن صفحه release';

  @override
  String get updateActionNotNow => 'بعداً';
}
