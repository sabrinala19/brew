# typed: false
# frozen_string_literal: true

require "digest/md5"
require "utils/curl"

# Archive API client.
#
# @api private
class Archive
  extend T::Sig

  include Context
  include Utils::Curl

  class Error < RuntimeError
  end

  sig { returns(String) }
  def inspect
    "#<Archive: item=#{@archive_item}>"
  end

  sig { params(item: T.nilable(String)).void }
  def initialize(item: "homebrew")
    @archive_item = item

    raise UsageError, "Must set the Archive item!" unless @archive_item

    ENV["HOMEBREW_FORCE_HOMEBREW_ON_LINUX"] = "1" if @archive_item == "homebrew" && !OS.mac?
  end

  def open_api(url, *args, auth: true)
    if auth
      raise UsageError, "HOMEBREW_ARCHIVE_KEY is unset." unless (key = Homebrew::EnvConfig.archive_key)

      if key.exclude?(":")
        raise UsageError,
              "Use HOMEBREW_ARCHIVE_KEY=access:secret. See https://archive.org/account/s3.php"
      end

      args += ["--header", "Authorization: AWS #{key}"]
    end

    curl(*args, url, print_stdout: false, secrets: key)
  end

  sig {
    params(local_file:    String,
           dir:           String,
           remote_file:   String,
           warn_on_error: T.nilable(T::Boolean)).void
  }
  def upload(local_file, dir:, remote_file:, warn_on_error: false)
    unless File.exist? local_file
      msg = "#{local_file} for upload doesn't exist!"
      raise Error, msg unless warn_on_error

      # Warn and return early here since we know this upload is going to fail.
      opoo msg
      return
    end

    md5_base64 = Digest::MD5.base64digest(File.read(local_file))
    url = "https://#{@archive_item}.s3.us.archive.org/#{dir}/#{remote_file}"
    args = ["--upload-file", local_file, "--header", "Content-MD5: #{md5_base64}"]
    args << "--fail" unless warn_on_error
    result = T.unsafe(self).open_api(url, *args)
    return if result.success? && result.stdout.exclude?("Error")

    msg = "Bottle upload failed: #{result.stdout}"
    raise msg unless warn_on_error

    opoo msg
  end

  sig { params(url: String).returns(T::Boolean) }
  def stable_mirrored?(url)
    headers, = curl_output("--connect-timeout", "15", "--location", "--head", url)
    status_code = headers.scan(%r{^HTTP/.* (\d+)}).last.first
    status_code.start_with?("2")
  end

  sig {
    params(formula:       Formula,
           dir:           String,
           warn_on_error: T::Boolean).returns(String)
  }
  def mirror_formula(formula, dir: "mirror", warn_on_error: false)
    formula.downloader.fetch

    filename = ERB::Util.url_encode(formula.downloader.basename)
    destination_url = "https://archive.org/download/#{@archive_item}/#{dir}/#{filename}"

    odebug "Uploading to #{destination_url}"

    upload(
      formula.downloader.cached_location,
      dir:           dir,
      remote_file:   filename,
      warn_on_error: warn_on_error,
    )

    destination_url
  end

  # Gets the MD5 hash of the specified remote file.
  #
  # @return the hash, the empty string (if the file doesn't have a hash), nil (if the file doesn't exist)
  sig { params(dir: String, remote_file: String).returns(T.nilable(String)) }
  def remote_md5(dir:, remote_file:)
    url = "https://#{@archive_item}.s3.us.archive.org/#{dir}/#{remote_file}"
    result = curl_output "--fail", "--silent", "--head", "--location", url
    if result.success?
      result.stdout.match(/^ETag: "(\h{32})"/)&.values_at(1)&.first || ""
    else
      raise Error if result.status.exitstatus != 22 && result.stderr.exclude?("404 Not Found")

      nil
    end
  end

  sig { params(directory: String, filename: String).returns(String) }
  def file_delete_instructions(directory, filename)
    <<~EOS
      Run:
        curl -X DELETE -H "Authorization: AWS $HOMEBREW_ARCHIVE_KEY" https://#{@archive_item}.s3.us.archive.org/#{directory}/#{filename}
      Or run:
        ia delete #{@archive_item} #{directory}/#{filename}
    EOS
  end

  sig {
    params(bottles_hash:  T::Hash[String, T.untyped],
           warn_on_error: T.nilable(T::Boolean)).void
  }
  def upload_bottles(bottles_hash, warn_on_error: false)
    bottles_hash.each do |_formula_name, bottle_hash|
      directory = bottle_hash["bintray"]["repository"]
      bottle_count = bottle_hash["bottle"]["tags"].length

      bottle_hash["bottle"]["tags"].each do |_tag, tag_hash|
        filename = tag_hash["filename"] # URL encoded in Bottle::Filename#archive
        delete_instructions = file_delete_instructions(directory, filename)

        local_filename = tag_hash["local_filename"]
        md5 = Digest::MD5.hexdigest(File.read(local_filename))

        odebug "Checking remote file #{@archive_item}/#{directory}/#{filename}"
        result = remote_md5(dir: directory, remote_file: filename)
        case result
        when nil
          # File doesn't exist.
          odebug "Uploading #{@archive_item}/#{directory}/#{filename}"
          upload(local_filename,
                 dir:           directory,
                 remote_file:   filename,
                 warn_on_error: warn_on_error)
        when md5
          # File exists, hash matches.
          odebug "#{filename} is already published with matching hash."
          bottle_count -= 1
        when ""
          # File exists, but can't find hash
          failed_message = "#{filename} is already published!"
          raise Error, "#{failed_message}\n#{delete_instructions}" unless warn_on_error

          opoo failed_message
        else
          # File exists, but hash either doesn't exist or is mismatched.
          failed_message = <<~EOS
            #{filename} is already published with a mismatched hash!
              Expected: #{md5}
              Actual:   #{result}
          EOS
          raise Error, "#{failed_message}#{delete_instructions}" unless warn_on_error

          opoo failed_message
        end
      end

      odebug "Uploaded #{bottle_count} bottles"
    end
  end
end
