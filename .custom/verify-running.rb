require 'json'
require 'openssl'

expected = ENV.fetch('EXPECTED_MASTODON_VERSION')
abort 'Wrong application version' unless Mastodon::Version.to_s == expected
abort 'Character limit changed' unless StatusLengthValidator::MAX_CHARS == 5000

ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
  settings = %w(trends_statuses_threshold trends_statuses_score_halflife_hours trends_tags_threshold trends_links_threshold).to_h do |key|
    [key, Setting.public_send(key)]
  end
  [Trends::Statuses, Trends::Tags, Trends::Links].each do |model|
    abort 'Invalid effective trend threshold' unless model.new.send(:effective_threshold).positive?
  end
  abort 'Invalid trend half-life' unless Trends::Statuses.new.send(:effective_score_halflife).positive?
  keys = 0
  Keypair.where.not(private_key: nil).find_each do |keypair|
    private_key = OpenSSL::PKey.read(keypair.private_key)
    public_key = OpenSSL::PKey.read(keypair.public_key)
    abort 'Account keypair mismatch' unless private_key.public_to_der == public_key.public_to_der
    keys += 1
  end
  puts JSON.generate(version: Mastodon::Version.to_s, max_characters: 5000, trend_settings: settings, verified_keypairs: keys, result: 'PASS')
end
