# Живая end-to-end проверка автопоиска и сборки каталога (как в менеджере).
# Каталог строится запросом к GitHub: готового списка в расширении нет.
# Запуск: ruby test/live_discovery_e2e.rb
$stdout.sync = true

require 'json'
require 'tmpdir'

module Sketchup
  $p = {}
  module_function

  def read_default(s, k, d = nil); $p.dig(s, k) || d; end
  def write_default(s, k, v); ($p[s] ||= {})[k] = v; end
  def require(pa); Kernel.require_relative("../src/#{pa}"); end
  def version; '24.0.0'; end
  def temp_dir; Dir.tmpdir; end
end

module UI
  module_function

  def start_timer(*); end
  def stop_timer(*); end
  def openURL(_u); end
  def messagebox(*); 6; end
  def menu(*)
    Class.new do
      def add_submenu(*); self; end
      def add_item(*); self; end
      def add_separator(*); self; end
    end.new
  end

  class Command
    def initialize(*); end

    def method_missing(*); self; end
    def respond_to_missing?(*); true; end
  end

  class Toolbar
    def initialize(*); end

    def any?(*); false; end
    def add_item(*); self; end
    def restore(*); end
  end
end

def file_loaded?(_); false; end
def file_loaded(_); true; end

require_relative '../shared/dn1sup_updater'
require_relative '../src/dn1sup_extension_store/main'

# Каталог строится запросом к GitHub (готового списка в расширении нет):
# сначала автопоиск репозиториев, затем опрос их релизов.
found = Dn1sup::ExtensionStore.discover_repos
puts "автопоиск нашёл репозиториев: #{found.size}"
found.each { |e| puts "  - #{e['id']} (#{e['repo']})" }
Dn1sup::ExtensionStore.instance_variable_set(:@discovered_entries, found)

repos = Dn1sup::ExtensionStore.merged_entries.map { |e| e['repo'] }.uniq
puts "репозиториев для опроса релизов: #{repos.size}"
repos.each { |r| Dn1sup::ExtensionStore.releases_list(r) }
prods = Dn1sup::ExtensionStore.collect_products_data(false, check_releases: false)
puts "продуктов в каталоге: #{prods.size}"
prods.each do |p|
  inst = p['installed_version'].to_s.empty? ? '-' : p['installed_version']
  flag = p['discovered'] ? ' DISCOVERED' : ''
  puts format('  %-24s latest:%-8s installed:%-8s%s', p['id'], p['latest_version'], inst, flag)
end

# Скрытие + снапшот по-настоящему
Dn1sup::ExtensionStore.save_release_snapshot
snap = JSON.parse(File.read(Dn1sup::ExtensionStore.snapshot_path))
puts "снапшот: v#{snap['version']}, релизов: #{snap['releases'].size}, discovered: #{snap['discovered'].size}"
