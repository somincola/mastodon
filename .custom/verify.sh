#!/bin/bash
set -euo pipefail

SOURCE_DIR="${1:-.}"

require_text() {
  local file="$1"
  local text="$2"

  if ! grep -Fq "$text" "$SOURCE_DIR/$file"; then
    echo "ERROR: Expected customization not found in $file: $text" >&2
    exit 1
  fi
}

echo "==> Verifying customizations in $SOURCE_DIR"

git -C "$SOURCE_DIR" diff --check

ruby -c "$SOURCE_DIR/app/models/trends/base.rb"
ruby -c "$SOURCE_DIR/app/models/trends/statuses.rb"
ruby -c "$SOURCE_DIR/app/models/trends/tags.rb"
ruby -c "$SOURCE_DIR/app/models/trends/links.rb"
ruby -c "$SOURCE_DIR/app/models/form/admin_settings.rb"
ruby -c "$SOURCE_DIR/spec/models/form/admin_settings_trends_spec.rb"
ruby -c "$SOURCE_DIR/spec/models/trends/configurable_settings_spec.rb"
ruby -c "$SOURCE_DIR/spec/system/admin/settings/discovery_trends_spec.rb"

ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load(File.read(path), aliases: true) }' \
  "$SOURCE_DIR/config/settings.yml" \
  "$SOURCE_DIR/config/locales/simple_form.en.yml" \
  "$SOURCE_DIR/config/locales/simple_form.zh-CN.yml"

require_text "app/validators/status_length_validator.rb" "MAX_CHARS = 5000"
require_text "app/models/trends/base.rb" "def configured_integer"
require_text "app/models/trends/statuses.rb" ":trends_statuses_threshold"
require_text "app/models/trends/statuses.rb" ":trends_statuses_score_halflife_hours"
require_text "app/models/trends/tags.rb" ":trends_tags_threshold"
require_text "app/models/trends/links.rb" ":trends_links_threshold"
require_text "app/views/admin/settings/discovery/show.html.haml" "f.input :trends_statuses_threshold"
require_text "app/views/admin/settings/discovery/show.html.haml" "f.input :trends_statuses_score_halflife_hours"
require_text "app/views/admin/settings/discovery/show.html.haml" "f.input :trends_tags_threshold"
require_text "app/views/admin/settings/discovery/show.html.haml" "f.input :trends_links_threshold"
require_text "config/locales/simple_form.en.yml" "trends_statuses_threshold: Trending posts threshold"
require_text "config/locales/simple_form.zh-CN.yml" "trends_statuses_threshold: 热门嘟文阈值"

echo "==> Customization verification passed"
