$stdout.sync = true
$stderr.sync = true

require 'net/http'
require 'json'
require 'tmpdir'

ENV['GITHUB_TOKEN'] ||= ENV['GH_TOKEN'] || (begin
  t = `gh auth token 2>nul`.strip
  t.empty? ? nil : t
rescue StandardError
  nil
end)

$dialog_log = []
$failed = 0

module Sketchup
  # Отдельных переключателей тулбара больше нет: у каждого расширения
  # всегда свой тулбар, менеджер всегда создаёт свой.
  $prefs = { 'Dn1supUpdater' => {}, 'DN1Sup ExtensionStore' => {} }

  module_function

  def read_default(section, key, default = nil)
    $prefs.fetch(section, {}).fetch(key, default)
  end

  def write_default(section, key, value)
    $prefs[section] ||= {}
    $prefs[section][key] = value
    true
  end

  def require(path)
    base = File.expand_path('..', __dir__)
    candidates = [
      path, # путь как есть (абсолютный: main.rb грузит updater из своей папки)
      File.join(base, 'src', path + '.rb'),
      File.join(base, 'src', path, path + '.rb'),
      File.join(base, 'gh-extensions', 'src', path + '.rb'),
      File.join(base, 'gh-extensions', 'src', path, path + '.rb'),
    ]
    candidates.each do |c|
      c += '.rb' unless File.extname(c) == '.rb'
      return Kernel.require(c) if File.file?(c)
    end
    nil
  end

  def version
    '24.0.0'
  end

  # Песочница вместо реального %TEMP%: снапшот каталога и логи теста не
  # должны задевать живые файлы Store (dn1sup_ext_releases.json и т.п.).
  $smoke_tmp = Dir.mktmpdir('dn1sup_smoke')

  def temp_dir
    $smoke_tmp
  end

  def install_from_archive(path, _show_warning = true)
    $dialog_log << "INSTALL_FROM_ARCHIVE: #{File.basename(path)} (#{File.size(path)} bytes)"
    true
  end
end

module UI
  module_function

  def messagebox(msg, _type = 0)
    $dialog_log << "MESSAGEBOX: #{msg}"
    if defined?($messagebox_queue) && $messagebox_queue.is_a?(Array) && !$messagebox_queue.empty?
      return $messagebox_queue.shift
    end
    IDYES
  end

  def savepanel(*args)
    $dialog_log << "SAVEPANEL: #{args.inspect}"
    return nil unless defined?($savepanel_result)
    $savepanel_result
  end

  def start_timer(*); end
  def openURL(url); $dialog_log << "OPEN_URL: #{url}"; end
  def inputbox(*); nil; end
  def menu(*)
    Class.new do
      def add_submenu(*); self; end
      def add_item(*); self; end
      def add_separator(*); self; end
    end.new
  end

  class Command
    def initialize(*); end

    def menu_text=(*);       self; end
    def tooltip=(*);         self; end
    def status_bar_text=(*); self; end
    def small_icon=(*);      self; end
    def large_icon=(*);      self; end
    def validation_proc=(*); self; end
  end

  class Toolbar
    def initialize(*); end

    def any?(*); false; end
    def add_item(*); $dialog_log << 'TOOLBAR_ITEM'; self; end
    def restore(*);  $dialog_log << 'TOOLBAR_RESTORE'; self; end
  end
end

IDYES = 6
IDNO  = 7
IDCANCEL = 2
MB_OK = 0
MB_YESNO = 4
MB_YESNOCANCEL = 3

def file_loaded?(_); false; end
def file_loaded(_); true; end

module Geom
  class Point3d; end
  class Vector3d; end
end

SKETCHUP_CONSOLE = Object.new
def SKETCHUP_CONSOLE.clear; end

$LOAD_PATH.unshift File.expand_path('../src', __dir__)
require_relative '../shared/dn1sup_updater'

# === ТЕСТЫ ===

def assert(label, cond, details = '')
  passed = !!cond
  puts(format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}"))
  $failed += 1 unless passed
end

# 1. Сравнение версий
assert 'norm_version', Dn1sup::Updater.norm_version('v1.2.10') == [1, 2, 10]
assert 'norm_version pre-release отбрасывается', Dn1sup::Updater.norm_version('v0.3.0-rc1') == [0, 3, 0]
assert 'norm_version build-метаданные отбрасываются', Dn1sup::Updater.norm_version('1.2.3+build.7') == [1, 2, 3]
assert('newer? 1.2.10 > 1.2.3', Dn1sup::Updater.newer?([1, 2, 10], [1, 2, 3]) == true)
assert('newer? 1.2.3 vs 1.2.10', Dn1sup::Updater.newer?([1, 2, 3], [1, 2, 10]) == false)
assert('newer? 0.3.0-rc1 не новее 0.3.0',
       Dn1sup::Updater.newer?(Dn1sup::Updater.norm_version('0.3.0-rc1'),
                               Dn1sup::Updater.norm_version('0.3.0')) == false)

# 2. Реальный GitHub API — последний релиз sketchup-mcp2
rel = Dn1sup::Updater.latest_release('zinin/sketchup-mcp2')
assert 'latest_release возвращает данные', rel.is_a?(Hash) && rel.key?('tag_name'), "tag_name=#{rel['tag_name']}"
assert 'release содержит assets', rel['assets'].is_a?(Array) && rel['assets'].any?, "#{rel['assets'].size} assets"

# 3. Скачивание .rbz через browser_download_url
asset = rel['assets'].find { |a| a['name'].to_s.end_with?('.rbz') }
assert 'есть .rbz asset', !!asset, asset && asset['name']
path = Dn1sup::Updater.download(asset['browser_download_url'], File.join(Dir.tmpdir, 'test_download.rbz'))
assert 'download succeeded', path && File.file?(path), path
assert 'скачанный файл — валидный RBZ', path && Dn1sup::Updater.rbz?(path)

# 4. Полный цикл install_from_url -> install_from_archive
ok = Dn1sup::Updater.install_from_url(asset['browser_download_url'], 'Test Extension')
assert 'install_from_url через install_from_archive', ok == true
log = $dialog_log.grep(/INSTALL_FROM_ARCHIVE/).last
assert 'install_from_archive зафиксирован', !!log, log

# 5. Полный цикл check! (silent, force — без pergola)
# Тест грузит апдейтер из рабочей копии (вне Plugins) — guard dev_source?
# отключаем стабом, логику check! тестируем напрямую (сам guard — в секции 21).
orig_dev_source = Dn1sup::Updater.method(:dev_source?)
Dn1sup::Updater.define_singleton_method(:dev_source?) { false }
begin
  summary = Dn1sup::Updater.check!(
    id: 'test', repo: 'zinin/sketchup-mcp2', version: '0.0.1',
    asset: asset['name'], force: true, silent: true
  )
ensure
  Dn1sup::Updater.define_singleton_method(:dev_source?, orig_dev_source)
end
assert 'check! вернул summary', summary.is_a?(Hash) && summary[:latest] == rel['tag_name'], summary.inspect
assert 'check! записал метку времени', Sketchup.read_default('Dn1supUpdater', 'last_test').is_a?(Integer)

# 5b. registry_entry: per-extension версия из per-repo манифеста (стаб сети)
orig_fetch_text = Dn1sup::Updater.method(:fetch_text)
Dn1sup::Updater.define_singleton_method(:fetch_text) do |url|
  if url.to_s.include?('dn1sup_time_project')
    JSON.generate([{ 'id' => 'dn1sup_time_project', 'name' => 'DN1Sup Time Project',
                     'repo' => 'dn1test/dn1sup_time_project', 'version' => '0.5.0' }])
  else
    '[]'
  end
end
begin
  reg_entry = Dn1sup::Updater.registry_entry('dn1test/dn1sup_time_project', 'dn1sup_time_project')
  assert 'registry_entry находит расширение в per-repo манифесте',
         reg_entry.is_a?(Hash) && reg_entry['version'].to_s == '0.5.0', reg_entry.inspect
  assert 'registry_entry для чужого id — nil',
         Dn1sup::Updater.registry_entry('dn1test/dn1sup_time_project', 'no_such_ext').nil?
ensure
  Dn1sup::Updater.define_singleton_method(:fetch_text, orig_fetch_text)
  Dn1sup::Updater.instance_variable_set(:@registry_cache, {})
end

# 6. fetch_text с raw.githubusercontent.com
ok = !Dn1sup::Updater.fetch_text('https://raw.githubusercontent.com/SketchUp/rubocop-sketchup/master/README.md').to_s.empty?
assert 'fetch_text raw.githubusercontent', ok

# 7. Несуществующий репозиторий не должен ронять код
bad = Dn1sup::Updater.latest_release('nonexistent-user-000/nonexistent-repo-999')
assert '404 -> {} (устойчивость)', bad == {}

# 7b. repo_meta: живой репозиторий существует, несуществующий — 404
live_meta = Dn1sup::Updater.repo_meta('dn1test/dn1sup_extension_store')
assert 'repo_meta: живой репозиторий — exists без renamed',
       live_meta.is_a?(Hash) && live_meta[:exists] == true && live_meta[:renamed] == false &&
       live_meta[:repo] == 'dn1test/dn1sup_extension_store', live_meta.inspect
gone_meta = Dn1sup::Updater.repo_meta('nonexistent-user-000/nonexistent-repo-999')
assert 'repo_meta: 404 -> exists: false', gone_meta == { exists: false }, gone_meta.inspect

# 8. Псевдоним log_last_error
assert 'log_last_error доступен', Dn1sup::Updater.respond_to?(:log_last_error)

# 9. Dn1sup::Updater.check! когда версия актуальна
current_summary = Dn1sup::Updater.check!(
  id: 'test', repo: 'zinin/sketchup-mcp2', version: rel['tag_name'],
  asset: asset['name'], force: true, silent: true
)
assert 'check! возвращает nil для актуальной версии', current_summary.nil?

# 10. Загрузка и проверка dn1sup_extension_store
require_relative '../src/dn1sup_extension_store/main'
Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dummy', '1.5.0')
assert 'ExtensionStore::installed_version fallback read_default', Dn1sup::ExtensionStore.installed_version('dummy') == '1.5.0'

assert 'тулбар создан с кнопкой каталога', $dialog_log.include?('TOOLBAR_ITEM')
assert 'тулбар показан (restore)', $dialog_log.include?('TOOLBAR_RESTORE')

# 10b. perform_uninstall: белый список id (path traversal) + сброс installed_at
require 'fileutils'
fake_plugins = Dir.mktmpdir
File.write(File.join(fake_plugins, 'other_plugin.rb'), '# соседний плагин — должен выжить')
FileUtils.mkdir_p(File.join(fake_plugins, 'dn1sup_save_settings'))
File.write(File.join(fake_plugins, 'dn1sup_save_settings', 'main.rb'), '# плагин под удаление')
File.write(File.join(fake_plugins, 'dn1sup_save_settings.rb'), '# loader под удаление')
Sketchup.define_singleton_method(:find_support_file) { |name| name == 'Plugins' ? fake_plugins : nil }
Sketchup.write_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', Time.now.to_i)

['.', '..', '../evil', 'foo', ''].each do |bad|
  r = Dn1sup::ExtensionStore.perform_uninstall(bad)
  assert "uninstall отклоняет #{bad.inspect}", r['ok'] == false, r.inspect
end
r = Dn1sup::ExtensionStore.perform_uninstall('dn1sup_nosuch')
assert 'uninstall отклоняет id вне реестра', r['ok'] == false, r.inspect
assert 'после отклонений соседний плагин цел', File.file?(File.join(fake_plugins, 'other_plugin.rb'))

r = Dn1sup::ExtensionStore.perform_uninstall('dn1sup_save_settings')
assert 'uninstall валидного id проходит', r['ok'] == true, r.inspect
assert 'файлы расширения удалены', !File.exist?(File.join(fake_plugins, 'dn1sup_save_settings')) &&
                                   !File.exist?(File.join(fake_plugins, 'dn1sup_save_settings.rb'))
assert 'installed_at сброшен', Sketchup.read_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', nil).nil?
assert 'соседний плагин не тронут', File.file?(File.join(fake_plugins, 'other_plugin.rb'))
Sketchup.singleton_class.send(:remove_method, :find_support_file)
FileUtils.remove_entry(fake_plugins)

# 10c. full_tag_name: полный тег из списка релизов, фолбэк v<version>
Dn1sup::ExtensionStore.instance_variable_set(
  :@releases_cache,
  'dn1test/tag_repo' => [{ 'tag_name' => '0.4.1' }, { 'tag_name' => 'v2.4.1' }]
)
assert 'full_tag_name: тег без префикса берётся как есть',
       Dn1sup::ExtensionStore.full_tag_name('dn1test/tag_repo', '0.4.1') == '0.4.1'
assert 'full_tag_name: v-тег из списка',
       Dn1sup::ExtensionStore.full_tag_name('dn1test/tag_repo', '2.4.1') == 'v2.4.1'
assert 'full_tag_name: фолбэк v<version>',
       Dn1sup::ExtensionStore.full_tag_name('dn1test/tag_repo', '9.9.9') == 'v9.9.9'
assert 'full_tag_name: пустой список — фолбэк',
       Dn1sup::ExtensionStore.full_tag_name('dn1test/other', '1.0.0') == 'v1.0.0'

# 11. Проверка prompt_pick при нажатии Cancel (UI.inputbox возвращает false)
assert 'prompt_pick обрабатывает false без исключений', Dn1sup::ExtensionStore.prompt_pick([{ 'name' => 'Test', 'installed_version' => nil }]).nil?

# 11b. latest_changelog_section: верхняя секция CHANGELOG.md (резерв «Что нового»)
sample_md = [
  '# Changelog', '', '## Unreleased', '', '## [0.2.0] — 2026-10-10',
  '- fix: правка два', '- feat: фича один', '', '### dn1sup_demo', '', '- внутренняя заметка', '',
  '## [0.1.0] — 2026-10-09', '- старт', ''
].join("\n")
section = Dn1sup::ExtensionStore.latest_changelog_section(sample_md)
assert 'latest_changelog_section: пропускает заголовки без версии (Unreleased)',
       !section.include?('Unreleased') && !section.include?('0.1.0')
assert 'latest_changelog_section: берёт тело верхней секции без строк заголовков',
       section.include?('fix: правка два') && section.include?('внутренняя заметка') &&
       !section.include?('0.2.0') && !section.include?('dn1sup_demo')
assert 'latest_changelog_section: не заходит в следующую секцию',
       !section.include?('старт')
assert 'latest_changelog_section: пустой ввод — пустая секция',
       Dn1sup::ExtensionStore.latest_changelog_section('').empty? &&
       Dn1sup::ExtensionStore.latest_changelog_section(nil).empty?

# 12. Проверка мгновенного сбора каталога без сети (offline mode):
# собственная запись Store всегда в каталоге, остальные — из найденного
# на GitHub и установленных в Plugins
offline_products = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
assert 'collect_products_data offline показывает Store', offline_products.any? { |p| p['id'] == 'dn1sup_extension_store' }
mgr_card = offline_products.find { |p| p['id'] == 'dn1sup_extension_store' }
assert 'карточка Store офлайн: версия из кода', !!mgr_card && mgr_card['latest_version'] == Dn1sup::ExtensionStore::VERSION,
       mgr_card && mgr_card.slice('latest_version', 'is_installed').inspect
assert 'каждая карточка имеет id и repo',
       offline_products.all? { |p| !p['id'].to_s.empty? && !p['repo'].to_s.empty? }

# 13. Протокол диалога: dispatch (единый колбэк call_ruby -> pushState/pushResult)
class FakeStoreDialog
  attr_reader :scripts

  def initialize
    @scripts = []
  end

  def add_action_callback(*); true;   end
  def visible?;               true;   end
  def execute_script(s);      @scripts << s; end
end

store_dlg = FakeStoreDialog.new
Dn1sup::ExtensionStore.instance_variable_set(:@dialog, store_dlg)

# defer_async синхронно: start_timer вызывает блок сразу (repeat=false в SketchUp
# — однократный вызов; здесь повторный вызов не нужен, т.к. работа синхронна)
orig_start_timer = UI.method(:start_timer)
UI.define_singleton_method(:start_timer) { |_interval, _repeat = false, &blk| blk&.call(:timer) }
UI.define_singleton_method(:stop_timer)  { |_timer| true }

begin
  # Предзаполняем кэш релизов: pushState уйдёт офлайн, без сетевых запросов
  entries = Dn1sup::ExtensionStore.merged_entries
  Dn1sup::ExtensionStore.instance_variable_set(
    :@release_cache,
    entries.each_with_object({}) { |e, h| h[e['repo'].to_s] = { 'tag_name' => 'v9.9.9' } }
  )
  # Откладываем автопоиск GitHub: dispatch-тесты должны быть офлайн
  Sketchup.write_default('DN1Sup ExtensionStore', 'last_discovery', Time.now.to_i)

  store_dlg.scripts.clear
  Dn1sup::ExtensionStore.dispatch(store_dlg, 'ready', '')
  pushed = store_dlg.scripts.grep(/\Awindow\.pushState\(/).last
  assert 'dispatch ready -> pushState', !!pushed, pushed.to_s[0, 120]
  assert 'pushState содержит version', pushed.to_s.include?('"version":')
  assert 'pushState содержит products', pushed.to_s.include?('"products":[')
  assert 'pushState содержит все расширения реестра', pushed.to_s.include?('"dn1sup_extension_store"')

  store_dlg.scripts.clear
  Dn1sup::ExtensionStore.dispatch(store_dlg, 'install', JSON.generate('id' => 'no_such_ext'))
  res_script = store_dlg.scripts.grep(/window\.pushResult\(/).last
  assert 'dispatch install неизвестного id -> pushResult ok:false', !!res_script && res_script.include?('false'), res_script.to_s[0, 160]

  store_dlg.scripts.clear
  Dn1sup::ExtensionStore.dispatch(store_dlg, 'confirm_uninstall', JSON.generate('id' => 'no_such_ext'))
  conf_script = store_dlg.scripts.grep(/window\.pushResult\(/).last
  assert 'dispatch confirm_uninstall -> pushResult(kind, payload)', !!conf_script && conf_script.include?('confirm_uninstall'), conf_script.to_s[0, 160]

  store_dlg.scripts.clear
  Dn1sup::ExtensionStore.dispatch(store_dlg, 'hide', JSON.generate('repo' => 'dn1test/dn1sup_dummy_found'))
  assert 'dispatch hide -> перерисовка каталога', store_dlg.scripts.grep(/\Awindow\.pushState\(/).any?
  assert 'dispatch hide записал pref', Sketchup.read_default('DN1Sup ExtensionStore', 'hidden_repos').to_s.include?('dn1sup_dummy_found')
  Dn1sup::ExtensionStore.unhide_all_repos

  before = $dialog_log.size
  Dn1sup::ExtensionStore.dispatch(store_dlg, 'неизвестная_команда', '')
  assert 'dispatch неизвестная команда не роняет код', $dialog_log.size >= before
ensure
  UI.define_singleton_method(:start_timer, orig_start_timer)
  UI.singleton_class.send(:remove_method, :stop_timer) rescue nil
  Dn1sup::ExtensionStore.instance_variable_set(:@dialog, nil)
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@fetching, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@pending_force, false)
  Dn1sup::ExtensionStore.unhide_all_repos
end

# 13b. Автопоиск расширений: слияние реестра и найденного, скрытие, коммиты,
# снапшот v3 (все проверки офлайн — найденное подкладывается в кэш руками)
discovered_fixture = [
  {
    'id'          => 'dn1sup_dummy_found',
    'name'        => 'DN1Sup Dummy Found',
    'description' => 'расширение, найденное на GitHub вне реестра',
    'repo'        => 'dn1test/dn1sup_dummy_found',
    'discovered'  => true
  }
]
begin
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, discovered_fixture)

  merged = Dn1sup::ExtensionStore.merged_entries
  assert 'merged_entries: реестр + найденное', merged.any? { |e| e['id'] == 'dn1sup_dummy_found' } && merged.any? { |e| e['id'] == 'dn1sup_extension_store' }
  assert 'find_entry находит найденное расширение', Dn1sup::ExtensionStore.find_entry('dn1sup_dummy_found').is_a?(Hash)

  # Дедупликация: повторные записи автопоиска (исторические снапшоты,
  # повторные запуски) не плодят карточки — одна копия на id/repo
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, Array.new(5) { discovered_fixture[0].dup })
  merged_dup = Dn1sup::ExtensionStore.merged_entries
  assert 'merged_entries: дубли найденного схлопнуты', merged_dup.count { |e| e['id'] == 'dn1sup_dummy_found' } == 1
  assert 'merged_entries: дубли не ломают реестр', merged_dup.count { |e| e['id'] == 'dn1sup_extension_store' } == 1
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, discovered_fixture)
  assert 'product_name для найденного расширения', Dn1sup::ExtensionStore.product_name('dn1sup_dummy_found') == 'DN1Sup Dummy Found'

  # Найденное без известных релизов в каталог не попадает
  offline = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
  assert 'collect: найденное без релизов скрыто', offline.none? { |p| p['discovered'] }

  # С известными релизами появляется карточка discovered (не установлено)
  Dn1sup::ExtensionStore.instance_variable_set(
    :@releases_cache,
    {
      'dn1test/dn1sup_dummy_found' => [
        {
          'tag_name' => 'v0.1.0', 'published_at' => '2026-10-01T00:00:00Z',
          'assets' => [{ 'name' => 'dn1sup_dummy_found.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }]
        }
      ]
    }
  )
  dummy = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false).find { |p| p['id'] == 'dn1sup_dummy_found' }
  assert 'collect: найденное с релизами показано', !!dummy && dummy['discovered'] == true
  assert 'collect: найденное помечено не установленным', !!dummy && dummy['is_installed'] == false
  assert 'collect: у найденного есть .rbz ассет', !!dummy && dummy['asset'] == 'dn1sup_dummy_found.rbz'

  # Коммиты из кэша попадают в payload при совпадении пары версий
  Dn1sup::ExtensionStore.instance_variable_set(
    :@commits_cache,
    { 'dn1test/dn1sup_dummy_found' => { 'installed' => '', 'offered' => '0.1.0', 'messages' => ['feat: demo'] } }
  )
  dummy2 = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false).find { |p| p['id'] == 'dn1sup_dummy_found' }
  assert 'collect: коммиты в payload при совпадении версий', !!dummy2 && dummy2['commits'] == ['feat: demo']

  # Скрытие найденного репозитория
  Dn1sup::ExtensionStore.hide_repo('dn1test/dn1sup_dummy_found')
  assert 'hide_repo: запись в pref', Sketchup.read_default('DN1Sup ExtensionStore', 'hidden_repos').to_s.include?('dn1sup_dummy_found')
  assert 'merged_entries: скрытое отфильтровано', Dn1sup::ExtensionStore.merged_entries.none? { |e| e['id'] == 'dn1sup_dummy_found' }
  Dn1sup::ExtensionStore.unhide_all_repos
  assert 'unhide_all_repos: pref очищен', Dn1sup::ExtensionStore.hidden_repos.empty?

  # Снапшот v3: найденные расширения и коммиты переживают перезапуск
  assert 'снапшот пишется в песочницу, не в живой %TEMP%',
         Dn1sup::ExtensionStore.snapshot_path.to_s.start_with?($smoke_tmp),
         Dn1sup::ExtensionStore.snapshot_path.to_s
  Dn1sup::ExtensionStore.save_release_snapshot
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@commits_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.load_release_snapshot
  assert 'снапшот v3: discovered восстановлен', Dn1sup::ExtensionStore.merged_entries.any? { |e| e['id'] == 'dn1sup_dummy_found' }
  assert 'снапшот v3: commits восстановлен',
         Dn1sup::ExtensionStore.instance_variable_get(:@commits_cache)['dn1test/dn1sup_dummy_found']['messages'] == ['feat: demo']
ensure
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@commits_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.unhide_all_repos
end

# 13c. Мёртвые/переименованные репозитории: repo_meta (офлайн, с подменой
# http_get), apply_repo_status, фильтрация карточек, снапшот v4.
# Живые проверки repo_meta — в секции 7b.
begin
  # --- repo_meta с подменой http_get --------------------------------------
  # body= у Net::HTTPResponse вне блока request бросает IOError — заполняем ivar'ы
  resp200 = lambda do |full_name|
    r = Net::HTTPSuccess.new('1.1', '200', 'OK')
    r.instance_variable_set(:@body, JSON.generate('full_name' => full_name))
    r.instance_variable_set(:@read, true)
    r
  end
  resp404 = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
  orig_http_get = Dn1sup::Updater.method(:http_get)
  Dn1sup::Updater.define_singleton_method(:http_get) { |_uri_or_str, _redirects = 5| $stub_http_response }

  $stub_http_response = resp200.call('dn1test/dn1sup_time_project')
  m = Dn1sup::Updater.repo_meta('dn1test/dn1sup_time_project')
  assert 'repo_meta: жив, имя совпадает', m == { exists: true, repo: 'dn1test/dn1sup_time_project', renamed: false }, m.inspect

  $stub_http_response = resp200.call('dn1test/dn1sup_new_name')
  m = Dn1sup::Updater.repo_meta('dn1test/dn1sup_old_name')
  assert 'repo_meta: переименован — новое имя и renamed',
         m == { exists: true, repo: 'dn1test/dn1sup_new_name', renamed: true }, m.inspect

  $stub_http_response = resp404
  assert 'repo_meta: 404 -> exists: false', Dn1sup::Updater.repo_meta('dn1test/dn1sup_old_name') == { exists: false }

  Dn1sup::Updater.define_singleton_method(:http_get) { |_u, _r = 5| raise Errno::ECONNREFUSED }
  assert 'repo_meta: сетевая ошибка -> nil (статус неизвестен)', Dn1sup::Updater.repo_meta('dn1test/x').nil?
ensure
  Dn1sup::Updater.define_singleton_method(:http_get, orig_http_get)
end

begin
  # --- apply_repo_status и фильтрация карточек ----------------------------
  # Установленное save_settings «переехало» в новый репозиторий: в каталоге
  # уже есть запись под новым именем (её принёс бы автопоиск), старая —
  # помечена переименованной.
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [
    discovered_fixture[0].dup,
    { 'id' => 'dn1sup_save_settings', 'name' => 'DN1Sup Save Settings',
      'description' => 'настройки', 'repo' => 'dn1test/dn1sup_save_settings_new', 'discovered' => true }
  ])
  Dn1sup::ExtensionStore.instance_variable_set(
    :@releases_cache,
    {
      'dn1test/dn1sup_dummy_found' => [{ 'tag_name' => 'v0.1.0', 'published_at' => '2026-10-01T00:00:00Z', 'assets' => [] }],
      'dn1test/dn1sup_save_settings_new' => [{ 'tag_name' => 'v1.0.0', 'published_at' => '2026-10-01T00:00:00Z', 'assets' => [] }]
    }
  )
  # save_settings считаем установленным: карточка с мёртвым репо должна
  # остаться в каталоге с пометкой
  Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dn1sup_save_settings', '1.0.0')

  Dn1sup::ExtensionStore.apply_repo_status(
    'dn1test/dn1sup_dummy_found'   => { exists: false },
    'dn1test/dn1sup_save_settings' => { exists: true, repo: 'dn1test/dn1sup_save_settings_new', renamed: true },
    'dn1test/dn1sup_extension_store'   => { exists: true, repo: 'dn1test/dn1sup_extension_store', renamed: false },
    'dn1test/unreachable'          => nil
  )
  stale_map = Dn1sup::ExtensionStore.instance_variable_get(:@stale_repos)
  assert 'apply: удалённый помечен gone', stale_map['dn1test/dn1sup_dummy_found']['status'] == 'gone'
  assert 'apply: переименованный помечен с новым именем',
         stale_map['dn1test/dn1sup_save_settings']['status'] == 'renamed' &&
         stale_map['dn1test/dn1sup_save_settings']['renamed_to'] == 'dn1test/dn1sup_save_settings_new'
  assert 'apply: живой репозиторий — ok', stale_map['dn1test/dn1sup_extension_store']['status'] == 'ok'
  assert 'apply: сеть (nil) — без пометки', stale_map['dn1test/unreachable'].nil?
  assert 'apply: stale? видит мёртвые',
         Dn1sup::ExtensionStore.stale?('dn1test/dn1sup_dummy_found') &&
         Dn1sup::ExtensionStore.stale?('dn1test/dn1sup_save_settings')
  assert 'apply: живой не stale', !Dn1sup::ExtensionStore.stale?('dn1test/dn1sup_extension_store')
  assert 'apply: кэш релизов мёртвого почищен',
         Dn1sup::ExtensionStore.instance_variable_get(:@releases_cache).none? { |repo, _| repo == 'dn1test/dn1sup_dummy_found' }
  assert 'apply: найденная запись мёртвого удалена',
         Dn1sup::ExtensionStore.instance_variable_get(:@discovered_entries).none? { |e| e['repo'] == 'dn1test/dn1sup_dummy_found' }

  products = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
  assert 'collect: неустановленное с мёртвым репо скрыто', products.none? { |p| p['id'] == 'dn1sup_dummy_found' }
  ss = products.find { |p| p['id'] == 'dn1sup_save_settings' }
  assert 'collect: установленное с переименованным репо осталось под новым именем',
         !!ss && ss['repo'] == 'dn1test/dn1sup_save_settings_new' &&
         ss['repo_status'].to_s.empty? && ss['is_installed'] == true && ss['has_update'] == false,
         ss&.slice('repo', 'repo_status', 'has_update').inspect
  em = products.find { |p| p['id'] == 'dn1sup_extension_store' }
  assert 'collect: живое расширение без пометки', !!em && em['repo_status'].to_s.empty?

  res = Dn1sup::ExtensionStore.perform_install('dn1sup_dummy_found')
  assert 'install: неизвестный id отклонён без сети', res['ok'] == false && res['error'].to_s.include?('не найдено'), res.inspect

  Dn1sup::ExtensionStore.apply_repo_status(
    'dn1test/dn1sup_save_settings' => { exists: true, repo: 'dn1test/dn1sup_save_settings', renamed: false }
  )
  assert 'apply: вернувшийся репозиторий перестаёт быть stale', !Dn1sup::ExtensionStore.stale?('dn1test/dn1sup_save_settings')
ensure
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@commits_cache, {})
  Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dn1sup_save_settings', nil)
end

begin
  # --- снапшот v6: статусы репозиториев и найденное переживают перезапуск --
  # (готового списка в расширении нет — только releases/discovered/commits/stale)
  Dn1sup::ExtensionStore.instance_variable_set(
    :@stale_repos,
    { 'dn1test/dn1sup_dummy_found' => { 'status' => 'gone', 'renamed_to' => '', 'checked_at' => 1_700_000_000 } }
  )
  Dn1sup::ExtensionStore.save_release_snapshot
  data = JSON.parse(File.read(Dn1sup::ExtensionStore.snapshot_path))
  assert 'снапшот v6: версия, stale, без полей центрального списка',
         data['version'] == 6 && data['stale'].is_a?(Hash) &&
         data['stale']['dn1test/dn1sup_dummy_found']['status'] == 'gone' &&
         !data.key?('remote_registry') && !data.key?('registry_meta'), "version=#{data['version']}"

  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.load_release_snapshot
  assert 'снапшот v6: stale восстановлен',
         Dn1sup::ExtensionStore.instance_variable_get(:@stale_repos)['dn1test/dn1sup_dummy_found']['status'] == 'gone'

  # Старый v5 с полями центрального списка читается, лишние поля игнорируются
  data['remote_registry'] = [{ 'id' => 'dn1sup_dummy_remote', 'repo' => 'dn1test/dn1sup_dummy_remote' }]
  data['registry_meta'] = { 'x' => { 'data' => { 'id' => 'x' }, 'at' => 1 } }
  data['version'] = 5
  File.write(Dn1sup::ExtensionStore.snapshot_path, JSON.generate(data))
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.load_release_snapshot
  assert 'снапшот v5 читается, лишние поля каталога игнорируются',
         Dn1sup::ExtensionStore.instance_variable_get(:@stale_repos)['dn1test/dn1sup_dummy_found']['status'] == 'gone' &&
         Dn1sup::ExtensionStore.merged_entries.none? { |e| e['id'] == 'dn1sup_dummy_remote' }

  # Самовосстановление: discovered-запись мёртвого репозитория из снапшота
  # (например, записанная версией без stale-логики) не resurrect-ится.
  data['discovered'] = [discovered_fixture[0]]
  File.write(Dn1sup::ExtensionStore.snapshot_path, JSON.generate(data))
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.load_release_snapshot
  assert 'снапшот: discovered мёртвого репо не восстановлен',
         Dn1sup::ExtensionStore.merged_entries.none? { |e| e['id'] == 'dn1sup_dummy_found' }
  data['discovered'] = []

  # Дедупликация discovered при загрузке снапшота: испорченные исторические
  # снапшоты (многократные копии одной записи) самолечатся
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  data['stale'] = {}
  data['version'] = Dn1sup::ExtensionStore::SNAPSHOT_VERSION
  data['discovered'] = Array.new(6) { discovered_fixture[0].dup }
  File.write(Dn1sup::ExtensionStore.snapshot_path, JSON.generate(data))
  Dn1sup::ExtensionStore.load_release_snapshot
  loaded_disc = Dn1sup::ExtensionStore.instance_variable_get(:@discovered_entries)
  assert 'снапшот: дубли discovered схлопнуты при загрузке', loaded_disc.size == 1
  Dn1sup::ExtensionStore.save_release_snapshot
  clean = JSON.parse(File.read(Dn1sup::ExtensionStore.snapshot_path))
  assert 'снапшот: перезаписывается чистыми данными', clean['discovered'].size == 1
  data['discovered'] = []

  # Старый формат v4 (без лишних полей) читается
  data.delete('remote_registry')
  data.delete('registry_meta')
  data['stale'] = { 'dn1test/dn1sup_dummy_found' => { 'status' => 'gone', 'renamed_to' => '', 'checked_at' => 1_700_000_000 } }
  data['version'] = 4
  File.write(Dn1sup::ExtensionStore.snapshot_path, JSON.generate(data))
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.load_release_snapshot
  assert 'снапшот v4 читается',
         Dn1sup::ExtensionStore.instance_variable_get(:@stale_repos)['dn1test/dn1sup_dummy_found']['status'] == 'gone'

  # Старый формат v3 (без stale) читается, stale остаётся пустым
  data.delete('stale')
  data['version'] = 3
  File.write(Dn1sup::ExtensionStore.snapshot_path, JSON.generate(data))
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.load_release_snapshot
  assert 'снапшот v3 без stale читается',
         Dn1sup::ExtensionStore.instance_variable_get(:@stale_repos).empty? &&
         Dn1sup::ExtensionStore.instance_variable_get(:@releases_cache).is_a?(Hash)
ensure
  Dn1sup::ExtensionStore.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@commits_cache, {})
end

# 13d. Per-repo метаданные обновляются с GitHub поверх найденного
# (и для неустановленных расширений), пустые поля данные не затирают (офлайн).
begin
  Dn1sup::ExtensionStore.instance_variable_set(
    :@discovered_entries,
    [{ 'id' => 'dn1sup_save_settings', 'name' => 'DN1Sup Save Settings',
       'description' => 'старое описание', 'repo' => 'dn1test/dn1sup_save_settings',
       'discovered' => true }]
  )
  # Без известных релизов карточка неустановленного скрыта — подкладываем
  # релиз, чтобы проверить сборку карточки из свежих данных каталога.
  Dn1sup::ExtensionStore.instance_variable_set(
    :@releases_cache,
    'dn1test/dn1sup_save_settings' => [
      { 'tag_name' => 'v1.0.0', 'published_at' => '2026-10-01T00:00:00Z',
        'assets' => [{ 'name' => 'dn1sup_save_settings.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }] }
    ]
  )
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})

  # Найденное с GitHub входит в каталог без центрального списка.
  merged = Dn1sup::ExtensionStore.merged_entries
  assert 'каталог без готового списка: Store всегда в каталоге',
         merged.any? { |e| e['id'] == 'dn1sup_extension_store' }
  assert 'каталог: найденное с GitHub входит в каталог',
         merged.any? { |e| e['id'] == 'dn1sup_save_settings' }

  # Per-repo дополнение точечно обновляет описание.
  Dn1sup::ExtensionStore.apply_discovered_meta(
    'dn1sup_save_settings' => { 'id' => 'dn1sup_save_settings', 'repo' => 'dn1test/dn1sup_save_settings',
                                'description' => 'свежее описание из репозитория расширения' }
  )
  ss2 = Dn1sup::ExtensionStore.merged_entries.find { |e| e['id'] == 'dn1sup_save_settings' }
  assert 'каталог: per-repo метаданные обновляют запись',
         ss2 && ss2['description'] == 'свежее описание из репозитория расширения'

  # Пустые поля per-repo данные не затирают.
  Dn1sup::ExtensionStore.apply_discovered_meta(
    'dn1sup_save_settings' => { 'id' => 'dn1sup_save_settings', 'repo' => 'dn1test/dn1sup_save_settings',
                                'description' => '', 'name' => '' }
  )
  ss3 = Dn1sup::ExtensionStore.merged_entries.find { |e| e['id'] == 'dn1sup_save_settings' }
  assert 'каталог: пустые per-repo поля не затирают данные',
         ss3 && ss3['description'] == 'свежее описание из репозитория расширения' && !ss3['name'].to_s.empty?

  # Карточка неустановленного строится из свежих данных каталога.
  card = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
                             .find { |p| p['id'] == 'dn1sup_save_settings' }
  assert 'карточка неустановленного со свежими данными',
         !!card && card['is_installed'] == false &&
         card['description'] == 'свежее описание из репозитория расширения', card&.slice('description', 'is_installed').inspect
ensure
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
end

# 14. Уровни логирования: краткий прикладной лог + [DEBUG] только при флаге debug
Dn1sup::Updater.log_info('smoke_test_probe_log_info')
Dn1sup::Updater.log_error(RuntimeError.new('smoke_test_probe_log_error'))
Dn1sup::Updater.log_debug('smoke_test_probe_log_debug')
slog = File.join(Sketchup.temp_dir, 'dn1sup_updater.log')
assert 'лог-файл создан', File.file?(slog), slog
if File.file?(slog)
  last_entries = File.readlines(slog, encoding: 'UTF-8').last(3).join
  assert 'log_info пишет [INFO] строку в лог', last_entries.include?('[INFO] smoke_test_probe_log_info'), last_entries
  assert 'log_error пишет [ERROR] строку в лог', last_entries.include?('[ERROR] RuntimeError: smoke_test_probe_log_error'), last_entries
  dbg_off = !last_entries.include?('[DEBUG] smoke_test_probe_log_debug')
  assert 'log_debug НЕ пишет без флага debug', dbg_off

  # Включаем debug-флаг, пере-тестируем
  $prefs['Dn1supUpdater']['debug'] = true
  Dn1sup::Updater.log_debug('smoke_test_probe_log_debug_on')
  line = File.readlines(slog, encoding: 'UTF-8').last
  assert 'log_debug пишет [DEBUG] с флагом debug', line.include?('[DEBUG] smoke_test_probe_log_debug_on'), line
  $prefs['Dn1supUpdater']['debug'] = nil
end

# 15. Краткие заметки для UI: markdown вычищен, ≤3 строки, ~200 символов
md = <<~BODY
  ### Extension Store (v0.6.2)
  - **Первый пункт** с `кодом` и [ссылкой](https://example.com/very/long/url)
  ![img](https://example.com/img.png)
  - **Второй пункт** — перенос
  третьей строки, а это длинный-предлинный четвёртый пункт описания который превышает лимит двести символов и потому будет аккуратно усечён по границе слова с многоточием в конце чтобы не ломать отображение в интерфейсе
BODY
sn = Dn1sup::Updater.short_notes(md)
assert 'short_notes: не содержит markdown-символов', ['**', '`', '](', '![', '### '].none? { |m| sn.include?(m) }, sn
assert 'short_notes: не более 3 строк', sn.lines.size <= 3, "строк: #{sn.lines.size}"
assert 'short_notes: длина в пределах', sn.length <= 210, "длина: #{sn.length}"
assert 'short_notes: markdown-текст -> plain', sn.include?('Первый пункт'), sn

# 16. Выбор предлагаемого релиза и статусы: сценарий смены схемы нумерации
# (реальная ситуация dn1sup_time_project: релиз v0.4.1 опубликован позже
# серии 2.4.x, /releases/latest указывает на 0.4.1 при установленной 2.4.1)
tp_list = [
  { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' },
  { 'tag_name' => 'v2.4.1', 'published_at' => '2026-10-07T14:45:39Z' },
  { 'tag_name' => 'v2.4.0', 'published_at' => '2026-10-07T05:28:57Z' }
]
tp_offered = Dn1sup::Updater.choose_release(tp_list)
assert 'choose_release берёт новейший по дате публикации', tp_offered['tag_name'] == 'v0.4.1', tp_offered['tag_name'].to_s
assert 'product_status: 0.3.0 -> 0.4.1 это update', Dn1sup::Updater.product_status('0.3.0', tp_offered, tp_list) == 'update'
assert 'product_status: 2.4.1 -> 0.4.1 это switch', Dn1sup::Updater.product_status('2.4.1', tp_offered, tp_list) == 'switch'
assert 'product_status: 2.4.0 -> 0.4.1 это switch', Dn1sup::Updater.product_status('2.4.0', tp_offered, tp_list) == 'switch'
assert 'product_status: 0.4.1 -> 0.4.1 это current', Dn1sup::Updater.product_status('0.4.1', tp_offered, tp_list) == 'current'
assert 'product_status: v-префикс нормализуется', Dn1sup::Updater.product_status('v0.4.1', tp_offered, tp_list) == 'current'
assert 'product_status: установленная новее, её релиза нет в списке — без предложения',
       Dn1sup::Updater.product_status('9.9.9', tp_offered, tp_list).nil?
assert 'product_status: 2.3.0 тоже ниже 0.4.1 отсутствует в списке — без предложения',
       Dn1sup::Updater.product_status('2.3.0', tp_offered, tp_list).nil?
assert 'product_status: не установлено — nil', Dn1sup::Updater.product_status(nil, tp_offered, tp_list).nil?
assert 'product_status: релизы недоступны — nil', Dn1sup::Updater.product_status('2.4.1', nil, []).nil?
# Если самый свежий по дате релиз — сама установленная версия (перепубликованный
# тег), предлагаемого действия нет; при равных датах предлагаемый не новее —
# тоже без предложения (строгое сравнение).
repub = [
  { 'tag_name' => 'v2.4.1', 'published_at' => '2026-10-11T00:00:00Z' },
  { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' }
]
assert 'product_status: перепубликованный установленный тег — current',
       Dn1sup::Updater.product_status('2.4.1', Dn1sup::Updater.choose_release(repub), repub) == 'current'
same_time = [
  { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' },
  { 'tag_name' => 'v2.4.1', 'published_at' => '2026-10-09T06:17:55Z' }
]
assert 'product_status: равные даты публикации — без предложения',
       Dn1sup::Updater.product_status('2.4.1', Dn1sup::Updater.choose_release(same_time), same_time).nil?
pre_list = [
  { 'tag_name' => 'v0.5.0-rc1', 'prerelease' => true, 'published_at' => '2026-10-10T00:00:00Z' },
  { 'tag_name' => 'v0.4.9', 'published_at' => '2026-10-01T00:00:00Z' }
]
assert 'choose_release пропускает prerelease', Dn1sup::Updater.choose_release(pre_list)['tag_name'] == 'v0.4.9'
assert 'choose_release пустой/битый список — nil', Dn1sup::Updater.choose_release([nil, 'x', {}]).nil?

# 16b. Дата-фолбэк: обновление по дате публикации релиза, а не только по номеру
assert 'installed_at: не задано — nil', Dn1sup::Updater.installed_at('date_none').nil?
Dn1sup::Updater.mark_installed('date_rt')
at = Dn1sup::Updater.installed_at('date_rt')
assert 'installed_at: mark_installed -> чтение', at.is_a?(Integer) && at > 0, at.inspect

repub_rel = {
  'tag_name' => 'v1.2.3', 'published_at' => '2026-10-09T00:00:00Z',
  'body' => 'hotfix без бампа версии', 'html_url' => 'https://example.com/r', 'assets' => []
}
cfg_date = { id: 'date_t1', repo: 'o/r', version: '1.2.3', asset: 'x.rbz' }

# Тот же номер версии, релиз издан позже установки -> предлагаем установку
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', 1_600_000_000)
s = Dn1sup::Updater.apply_check(cfg_date, { release: repub_rel, latest: '1.2.3', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: переизданный релиз той же версии — обновление по дате',
       s.is_a?(Hash) && s[:same_version] == true, s.inspect

# Релиз старее установленной сборки — прежнее «актуальная версия»
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', 1_900_000_000)
s = Dn1sup::Updater.apply_check(cfg_date, { release: repub_rel, latest: '1.2.3', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: релиз старее установки — nil', s.nil?

# Дата установки неизвестна (ручная установка) — прежнее поведение
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', nil)
s = Dn1sup::Updater.apply_check(cfg_date, { release: repub_rel, latest: '1.2.3', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: без даты установки — nil', s.nil?

# Монорепо: версия из registry не совпадает с тегом релиза — релиз чужой,
# его дату сравнивать нельзя
cfg_mono = { id: 'date_t2', repo: 'o/r', version: '2.0.0', asset: 'y.rbz' }
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t2', 1_600_000_000)
s = Dn1sup::Updater.apply_check(cfg_mono, { release: repub_rel, latest: '2.0.0', from_registry: true },
                                force: true, silent: true)
assert 'apply_check: монорепо, чужой тег релиза — nil', s.nil?

# Монорепо: версия из registry совпадает с тегом — дата-фолбэк работает
mono_rel = repub_rel.merge('tag_name' => 'v2.0.0')
s = Dn1sup::Updater.apply_check(cfg_mono, { release: mono_rel, latest: '2.0.0', from_registry: true },
                                force: true, silent: true)
assert 'apply_check: монорепо, тег соответствует — обновление по дате',
       s.is_a?(Hash) && s[:same_version] == true, s.inspect

# Численно новая версия — как раньше, без даты установки и без флага
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', nil)
new_rel = repub_rel.merge('tag_name' => 'v1.3.0')
s = Dn1sup::Updater.apply_check(cfg_date, { release: new_rel, latest: '1.3.0', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: новая версия — update как раньше, без same_version',
       s.is_a?(Hash) && !s.key?(:same_version), s.inspect

# product_status: фолбэк на дату установки, когда релиза установленной версии
# нет в списке
older_install = 1_600_000_000   # 2020-09, раньше релиза 0.4.1 (2026-10)
newer_install = 1_900_000_000   # 2030-03, позже релиза
v041 = { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' }
assert 'product_status: релиза нет в списке, установка старее — switch',
       Dn1sup::Updater.product_status('1.0.0', v041, [], installed_at: older_install) == 'switch'
assert 'product_status: релиза нет в списке, установка новее — nil',
       Dn1sup::Updater.product_status('1.0.0', v041, [], installed_at: newer_install).nil?
assert 'product_status: релиза нет в списке, даты нет — nil (как раньше)',
       Dn1sup::Updater.product_status('1.0.0', v041, []).nil?
# Переизпуск той же версии: релиз опубликован позже установки
assert 'product_status: та же версия, переиздана позже установки — switch',
       Dn1sup::Updater.product_status('0.4.1', v041, [v041], installed_at: older_install) == 'switch'
assert 'product_status: та же версия, установка позже релиза — current',
       Dn1sup::Updater.product_status('0.4.1', v041, [v041], installed_at: newer_install) == 'current'

# 17. Живой список релизов GET /releases
live_releases = Dn1sup::Updater.releases('zinin/sketchup-mcp2')
assert 'releases возвращает непустой массив', live_releases.is_a?(Array) && live_releases.any?, "#{live_releases.size} релизов"
live_offered = Dn1sup::Updater.choose_release(live_releases)
assert 'choose_release по живому списку даёт тег из этого списка',
       live_offered && live_releases.any? { |r| r['tag_name'] == live_offered['tag_name'] }, live_offered && live_offered['tag_name']
bad_releases = Dn1sup::Updater.releases('nonexistent-user-000/nonexistent-repo-999')
assert 'releases 404 -> [] (устойчивость)', bad_releases == []

# 18. Автопоиск: репозитории аккаунта dn1test (живой GitHub)
owner_repos = Dn1sup::Updater.repos_of_owner('dn1test')
assert 'repos_of_owner возвращает репозитории', owner_repos.is_a?(Array) && owner_repos.any?, "#{owner_repos.size} репозиториев"
assert 'repos_of_owner содержит менеджер', owner_repos.any? { |r| r['full_name'] == 'dn1test/dn1sup_extension_store' }
assert 'repos_of_owner неизвестный аккаунт -> []', Dn1sup::Updater.repos_of_owner('nonexistent-user-000-zzz') == []

# 19. Лог правок: коммиты между тегами (живой GitHub)
cmts = Dn1sup::Updater.compare_commits('dn1test/dn1sup_time_project', 'v0.4.1', 'v0.5.0', limit: 5)
assert 'compare_commits возвращает сообщения', cmts.is_a?(Array) && cmts.any?, cmts.inspect
assert 'compare_commits: непустые строки', cmts.all? { |m| m.is_a?(String) && !m.strip.empty? }
assert 'compare_commits: несуществующие теги -> []',
       Dn1sup::Updater.compare_commits('dn1test/dn1sup_time_project', 'v9.9.9', 'v0.0.1') == []

# 20. Каталог без готового списка (один id, без dev-двойников) + установка/обновление
# (офлайн: сеть подменяется стабами)
begin
  self_e = Dn1sup::ExtensionStore.self_entry
  assert 'self_entry: id/repo/version из кода',
         self_e['id'] == 'dn1sup_extension_store' &&
         self_e['repo'] == 'dn1test/dn1sup_extension_store' &&
         self_e['version'].to_s == Dn1sup::ExtensionStore::VERSION, self_e.inspect
  merged_all = Dn1sup::ExtensionStore.merged_entries
  ids = merged_all.map { |e| e['id'].to_s }
  repos = merged_all.map { |e| e['repo'].to_s }
  assert 'каталог без готового списка: Store всегда в каталоге', ids.include?('dn1sup_extension_store')
  assert 'каталог: id уникальны', ids.uniq.size == ids.size, ids.inspect
  assert 'каталог: repo уникальны', repos.uniq.size == repos.size, repos.inspect
  assert 'каталог: без _dev записей', ids.none? { |id| id.end_with?('_dev') }

  Dn1sup::ExtensionStore.instance_variable_set(
    :@discovered_entries,
    [{ 'id' => 'dn1sup_save_settings', 'name' => 'DN1Sup Save Settings',
       'description' => 'настройки', 'repo' => 'dn1test/dn1sup_save_settings', 'discovered' => true }]
  )

  fake_release = {
    'tag_name' => 'v9.9.9',
    'assets' => [{ 'name' => 'dn1sup_save_settings.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }]
  }
  orig_latest = Dn1sup::Updater.method(:latest_release)
  orig_install = Dn1sup::Updater.method(:install_from_url)
  Dn1sup::Updater.define_singleton_method(:latest_release) { |*_a| fake_release }
  Dn1sup::Updater.define_singleton_method(:install_from_url) { |*_a, **_k| true }

  res = Dn1sup::ExtensionStore.perform_install('dn1sup_save_settings')
  assert 'install: ok', res['ok'] == true, res.inspect
  assert 'install: сообщение без dev-пометки', !res['message'].to_s.include?('Dev-вариант')
  assert 'install: без флага dev_replaced', !res.key?('dev_replaced')

  upd = Dn1sup::ExtensionStore.perform_update('dn1sup_save_settings')
  assert 'update: делегирует install', upd['ok'] == true, upd.inspect
ensure
  Dn1sup::Updater.define_singleton_method(:latest_release, orig_latest)
  Dn1sup::Updater.define_singleton_method(:install_from_url, orig_install)
  Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dn1sup_save_settings', nil)
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
end

# 21. dev_source?: self-update отключён для рабочей копии (один id + reload)
begin
  # Тест исполняется из рабочей копии репозитория (вне Plugins) — guard срабатывает
  assert 'dev_source?: рабочая копия вне Plugins', Dn1sup::Updater.dev_source? == true
  cfg_dev = { id: 'dev_src_probe', repo: 'o/r', version: '0.0.1', asset: 'x.rbz' }
  assert 'check!: рабочая копия — без сетевых запросов (nil)',
         Dn1sup::Updater.check!(cfg_dev).nil?
end

# 22. Кнопка «Обновить»: сводка sync, единый предлагаемый релиз, guard
begin
  assert 'REPO_CHECK_TTL задан для экономии квоты', Dn1sup::ExtensionStore::REPO_CHECK_TTL.to_i >= 60

  # offered_release: список релизов приоритетнее одиночного /latest
  orig_releases = Dn1sup::Updater.method(:releases)
  orig_latest2 = Dn1sup::Updater.method(:latest_release)
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::Updater.define_singleton_method(:releases) do |*_a, **_k|
    [{ 'tag_name' => 'v2.0.0', 'published_at' => '2026-10-10T00:00:00Z', 'assets' => [] }]
  end
  Dn1sup::Updater.define_singleton_method(:latest_release) { |*_a| { 'tag_name' => 'v9.9.9', 'assets' => [] } }
  off = Dn1sup::ExtensionStore.offered_release('o/r', true)
  assert 'offered_release: список важнее одиночного latest', off && off['tag_name'] == 'v2.0.0', off.inspect
  Dn1sup::Updater.define_singleton_method(:releases) { |*_a, **_k| [] }
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  off2 = Dn1sup::ExtensionStore.offered_release('o/r', true)
  assert 'offered_release: пустой список — фолбэк на latest', off2 && off2['tag_name'] == 'v9.9.9', off2.inspect
  Dn1sup::Updater.define_singleton_method(:releases, orig_releases)
  Dn1sup::Updater.define_singleton_method(:latest_release, orig_latest2)
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})

  # has_asset: релиз без .rbz помечается для UI
  Dn1sup::ExtensionStore.instance_variable_set(
    :@discovered_entries,
    [{ 'id' => 'dn1sup_save_settings', 'name' => 'DN1Sup Save Settings',
       'description' => 'настройки', 'repo' => 'dn1test/dn1sup_save_settings', 'discovered' => true }]
  )
  Dn1sup::ExtensionStore.instance_variable_set(
    :@releases_cache,
    'dn1test/dn1sup_save_settings' => [
      { 'tag_name' => 'v9.9.9', 'published_at' => '2026-10-10T00:00:00Z', 'assets' => [] }
    ]
  )
  no_asset = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
                                     .find { |p| p['id'] == 'dn1sup_save_settings' }
  assert 'collect: релиз без .rbz — has_asset false', !!no_asset && no_asset['has_asset'] == false, no_asset.inspect
  Dn1sup::ExtensionStore.instance_variable_set(
    :@releases_cache,
    'dn1test/dn1sup_save_settings' => [
      { 'tag_name' => 'v9.9.9', 'published_at' => '2026-10-10T00:00:00Z',
        'assets' => [{ 'name' => 'dn1sup_save_settings.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }] }
    ]
  )
  with_asset = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
                                        .find { |p| p['id'] == 'dn1sup_save_settings' }
  assert 'collect: релиз с .rbz — has_asset true', !!with_asset && with_asset['has_asset'] == true, with_asset.inspect
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})

  # push_state несёт сводку sync (счётчик «проверено X/Y» для кнопки)
  dlg2 = FakeStoreDialog.new
  Dn1sup::ExtensionStore.instance_variable_set(:@fetching, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@pending_force, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@sync_status,
                                           { 'fetching' => false, 'fetched' => 7, 'total' => 9,
                                             'failed' => ['o/a'], 'checked_at' => 1_700_000_000,
                                             'snapshot_saved_at' => 1_699_999_000 })
  dlg2.scripts.clear
  Dn1sup::ExtensionStore.push_state(dlg2, [])
  sync_script = dlg2.scripts.grep(/\Awindow\.pushState\(/).last.to_s
  assert 'push_state содержит sync', sync_script.include?('"sync":'), sync_script[0, 160]
  assert 'push_state sync: счётчик fetched/total', sync_script.include?('"fetched":7') && sync_script.include?('"total":9'), sync_script[0, 200]
  Dn1sup::ExtensionStore.instance_variable_set(:@sync_status,
                                           { 'fetching' => false, 'fetched' => 0, 'total' => 0,
                                             'failed' => [], 'checked_at' => 0, 'snapshot_saved_at' => 0 })

  # seed_installed_at_baseline: ручной установке ставится базовая дата
  Sketchup.write_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', nil)
  Dn1sup::ExtensionStore.seed_installed_at_baseline([{ 'id' => 'dn1sup_save_settings', 'is_installed' => true }])
  assert 'seed: базовая дата установки ставится', !Dn1sup::Updater.installed_at('dn1sup_save_settings').nil?
  Sketchup.write_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', nil)

  # guard: повторный refresh во время обхода коалесцируется
  dlg3 = FakeStoreDialog.new
  Dn1sup::ExtensionStore.instance_variable_set(:@dialog, dlg3)
  Dn1sup::ExtensionStore.instance_variable_set(:@fetching, true)
  Dn1sup::ExtensionStore.instance_variable_set(:@pending_force, false)
  Dn1sup::ExtensionStore.send_products_to_dialog(force: true)
  assert 'guard: повторный force коалесцирован', Dn1sup::ExtensionStore.instance_variable_get(:@pending_force) == true
  Dn1sup::ExtensionStore.instance_variable_set(:@fetching, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@pending_force, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@dialog, nil)
ensure
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtensionStore.instance_variable_set(:@fetching, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@pending_force, false)
  Dn1sup::ExtensionStore.instance_variable_set(:@dialog, nil)
end

# 23. Выбор свежайшей версии (только GitHub) и проверка карточки
begin
  assert 'pick: только локаль', Dn1sup::Updater.pick_freshest('1.0.0', '1.1.0', '') == :local
  assert 'pick: только github', Dn1sup::Updater.pick_freshest('1.0.0', '', '1.1.0') == :github
  assert 'pick: ни того ни другого', Dn1sup::Updater.pick_freshest('1.0.0', '', '') == :unknown
  assert 'pick: локаль свежее github', Dn1sup::Updater.pick_freshest('1.0.0', '2.0.0', '1.5.0') == :local
  assert 'pick: github свежее локали', Dn1sup::Updater.pick_freshest('1.0.0', '1.5.0', '2.0.0') == :github
  assert 'pick: актуальная', Dn1sup::Updater.pick_freshest('2.0.0', '2.0.0', '2.0.0') == :current
  assert 'pick: не установлено — свежее из двух',
         Dn1sup::Updater.pick_freshest('', '1.0.0', '2.0.0') == :github
  assert 'pick: не установлено, только локаль',
         Dn1sup::Updater.pick_freshest(nil, '1.0.0', nil) == :local
  # 23b. Выбор свежайшей по дате/времени при равном номере версии
  assert 'pick: равные версии без дат — current (без переустановок)',
         Dn1sup::Updater.pick_freshest('0.17.0', '', '0.17.0') == :current
  assert 'pick: равные версии без дат, только локаль — current',
         Dn1sup::Updater.pick_freshest('0.17.0', '0.17.0', '') == :current
  assert 'pick: та же версия, релиз свежее установки — github',
         Dn1sup::Updater.pick_freshest('1.2.3', '', '1.2.3',
                                        installed_at: 1_600_000_000,
                                        github_time: '2026-10-09T00:00:00Z') == :github
  assert 'pick: та же версия, релиз старее установки — current',
         Dn1sup::Updater.pick_freshest('1.2.3', '', '1.2.3',
                                        installed_at: 1_900_000_000,
                                        github_time: '2026-10-09T00:00:00Z') == :current
  assert 'pick: ниже по номеру, но свежее по дате (switch) — github',
         Dn1sup::Updater.pick_freshest('2.4.1', '', '0.4.1',
                                        installed_at: 1_600_000_000,
                                        github_time: '2026-10-09T06:17:55Z') == :github
  assert 'pick: ниже по номеру и старее по дате — current',
         Dn1sup::Updater.pick_freshest('2.4.1', '', '0.4.1',
                                        installed_at: 1_900_000_000,
                                        github_time: '2026-10-09T06:17:55Z') == :current
  assert 'pick: локаль равна, но файлы свежее — local',
         Dn1sup::Updater.pick_freshest('1.2.0', '1.2.0', '1.0.0',
                                        installed_at: 1_600_000_000,
                                        local_time: 1_700_000_000,
                                        github_time: '2026-01-01T00:00:00Z') == :local
  assert 'to_unixtime: ISO-строка и число',
         Dn1sup::Updater.to_unixtime('2026-10-09T00:00:00Z') == Time.parse('2026-10-09T00:00:00Z').to_i &&
         Dn1sup::Updater.to_unixtime(1_600_000_000) == 1_600_000_000 &&
         Dn1sup::Updater.to_unixtime(nil) == 0 && Dn1sup::Updater.to_unixtime('') == 0
  orig_releases3 = Dn1sup::Updater.method(:releases)
  orig_latest3 = Dn1sup::Updater.method(:latest_release)
  Dn1sup::Updater.define_singleton_method(:releases) { |*_a, **_k| [] }
  Dn1sup::Updater.define_singleton_method(:latest_release) { |*_a| {} }
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  # Запись каталога — из автопоиска (готового списка в расширении нет)
  Dn1sup::ExtensionStore.instance_variable_set(
    :@discovered_entries,
    [{ 'id' => 'dn1sup_save_settings', 'name' => 'DN1Sup Save Settings',
       'description' => 'настройки', 'repo' => 'dn1test/dn1sup_save_settings',
       'discovered' => true }]
  )

  # Релизы GitHub недоступны — честная ошибка (локальных источников больше нет)
  res = Dn1sup::ExtensionStore.perform_check_update('dn1sup_save_settings')
  assert 'check_update: релизы недоступны — ok:false', res['ok'] == false, res.inspect

  # Дата/время: та же версия, но релиз GitHub свежее установки — обновление;
  # релиз старее установки — «актуальная версия» (без переустановки).
  begin
    date_id = 'dn1sup_save_settings'
    saved_lists = Dn1sup::ExtensionStore.instance_variable_get(:@releases_cache)
    saved_cache = Dn1sup::ExtensionStore.instance_variable_get(:@release_cache)
    orig_install_url = Dn1sup::Updater.method(:install_from_url)
    Dn1sup::Updater.define_singleton_method(:releases) do |*_a, **_k|
      [{ 'tag_name' => 'v1.0.0', 'published_at' => '2026-10-09T00:00:00Z',
         'assets' => [{ 'name' => 'dn1sup_save_settings.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }] }]
    end
    Dn1sup::Updater.define_singleton_method(:install_from_url) { |*_a, **_k| true }
    Sketchup.write_default('DN1Sup ExtensionStore', "installed_#{date_id}", '1.0.0')
    Sketchup.write_default('Dn1supUpdater', "installed_at_#{date_id}", 1_600_000_000)
    Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
    Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
    res = Dn1sup::ExtensionStore.perform_check_update(date_id)
    assert 'check_update: та же версия, релиз свежее — обновление', res['ok'] == true, res.inspect
    Sketchup.write_default('Dn1supUpdater', "installed_at_#{date_id}", 1_900_000_000)
    Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
    Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
    res = Dn1sup::ExtensionStore.perform_check_update(date_id)
    assert 'check_update: та же версия, релиз старее — актуальная',
           res['ok'] == true && res['message'].to_s.include?('актуальная'), res.inspect
  ensure
    Dn1sup::Updater.define_singleton_method(:install_from_url, orig_install_url)
    Dn1sup::Updater.define_singleton_method(:releases) { |*_a, **_k| [] }
    Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, saved_lists)
    Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, saved_cache)
    Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dn1sup_save_settings', nil)
    Sketchup.write_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', nil)
  end

  prods = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
  assert 'collect: карточки без dev-полей читаются', prods.is_a?(Array), prods.inspect
ensure
  Dn1sup::Updater.define_singleton_method(:releases, orig_releases3)
  Dn1sup::Updater.define_singleton_method(:latest_release, orig_latest3)
  Dn1sup::ExtensionStore.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
end

# 24. Смешанные копии апдейтера в Plugins: старый модуль в памяти не роняет
# установку/проверку (симптом: "wrong number of arguments (given 4, expected 3)").
begin
  orig_pick24 = Dn1sup::Updater.method(:pick_freshest)
  orig_status24 = Dn1sup::Updater.method(:product_status)
  orig_install_url24 = Dn1sup::Updater.method(:install_from_url)
  orig_mtime24 = Dn1sup::Updater.method(:local_dev_mtime)

  # Новые методы принимают позиционный Hash опций (упаковка kwargs на Ruby 2.7)
  assert 'pick: позиционный Hash опций вместо kwargs',
         Dn1sup::Updater.pick_freshest('1.2.3', '', '1.2.3',
                                        { installed_at: 1_600_000_000,
                                          github_time: '2026-10-09T00:00:00Z' }) == :github
  assert 'product_status: позиционный Hash опций вместо kwargs',
         Dn1sup::Updater.product_status(
           '0.4.1',
           { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' },
           [{ 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' }],
           { installed_at: 1_600_000_000 }) == 'switch'

  # Симуляция старого апдейтера из соседнего расширения: методы без kwargs,
  # без local_dev_mtime и без UPDATER_VERSION (как v0.16.0 и старше).
  Dn1sup::Updater.define_singleton_method(:pick_freshest) do |inst, loc, gh|
    if loc.to_s.empty? && gh.to_s.empty?
      :unknown
    elsif loc.to_s.empty?
      :github
    elsif gh.to_s.empty?
      :local
    elsif inst.to_s.empty?
      :github
    else
      :current
    end
  end
  Dn1sup::Updater.define_singleton_method(:product_status) do |inst, offered, _list = nil|
    if inst.to_s.empty?
      nil
    elsif offered.is_a?(Hash) && offered['tag_name'].to_s.sub(/\Av/i, '') == inst.to_s.sub(/\Av/i, '')
      'current'
    else
      'update'
    end
  end
  Dn1sup::Updater.define_singleton_method(:install_from_url) { |*_a| true }
  Dn1sup::Updater.singleton_class.send(:remove_method, :local_dev_mtime)
  Dn1sup::Updater.send(:remove_const, :UPDATER_VERSION)

  # Прямой вызов нового стиля против старого метода — та самая ошибка из тоста
  begin
    Dn1sup::Updater.pick_freshest('1.0', '1.0', '1.0',
                                   installed_at: 1, github_time: 2, local_time: 3)
    assert 'старый pick_freshest: kwargs роняют вызов', false
  rescue ArgumentError => e
    assert 'старый pick_freshest: текст ошибки как в тосте', e.message =~ /given 4, expected 3/, e.message
  end

  # Фолбэк без догрузки (bundled-версия 0 — load пропускается): установка
  # идёт по старому поведению, исключений нет.
  Dn1sup::ExtensionStore.instance_variable_set(:@bundled_updater_version, 0)
  orig_releases24 = Dn1sup::Updater.method(:releases)
  orig_latest24 = Dn1sup::Updater.method(:latest_release)
  fake_release24 = {
    'tag_name' => 'v9.9.9',
    'assets' => [{ 'name' => 'dn1sup_save_settings.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }]
  }
  Dn1sup::Updater.define_singleton_method(:releases) { |*_a, **_k| [] }
  Dn1sup::Updater.define_singleton_method(:latest_release) { |*_a| fake_release24 }
  # Запись каталога — из автопоиска (готового списка в расширении нет)
  Dn1sup::ExtensionStore.instance_variable_set(
    :@discovered_entries,
    [{ 'id' => 'dn1sup_save_settings', 'name' => 'DN1Sup Save Settings',
       'description' => 'настройки', 'repo' => 'dn1test/dn1sup_save_settings',
       'discovered' => true }]
  )
  res = Dn1sup::ExtensionStore.perform_install('dn1sup_save_settings')
  assert 'install против старого апдейтера: ok без исключения', res['ok'] == true, res.inspect
  assert 'install против старого апдейтера: без тоста про исключение',
         !res['error'].to_s.include?('Исключение'), res.inspect
  Dn1sup::Updater.define_singleton_method(:releases, orig_releases24)
  Dn1sup::Updater.define_singleton_method(:latest_release, orig_latest24)
  Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dn1sup_save_settings', nil)

  # Самолечение: ensure_updater! догружает bundled-копию менеджера (v5),
  # kwargs-вызовы снова работают в полную силу (с датами).
  Dn1sup::ExtensionStore.send(:remove_instance_variable, :@bundled_updater_version)
  Dn1sup::ExtensionStore.ensure_updater!
  assert 'ensure_updater!: версия модуля — 5',
         defined?(Dn1sup::Updater::UPDATER_VERSION) && Dn1sup::Updater::UPDATER_VERSION.to_i == 5
  assert 'ensure_updater!: kwargs снова принимаются',
         Dn1sup::Updater.method(:pick_freshest).parameters.any? { |t, _| t == :key }
  assert 'ensure_updater!: даты снова учитываются',
         Dn1sup::Updater.pick_freshest('1.2.3', '', '1.2.3',
                                        installed_at: 1_600_000_000,
                                        github_time: '2026-10-09T00:00:00Z') == :github
ensure
  Dn1sup::Updater.define_singleton_method(:pick_freshest, orig_pick24)
  Dn1sup::Updater.define_singleton_method(:product_status, orig_status24)
  Dn1sup::Updater.define_singleton_method(:install_from_url, orig_install_url24)
  Dn1sup::Updater.define_singleton_method(:local_dev_mtime, orig_mtime24)
  Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, [])
  Sketchup.write_default('DN1Sup ExtensionStore', 'installed_dn1sup_save_settings', nil)
end

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
