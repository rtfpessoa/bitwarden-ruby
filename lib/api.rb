#
# Copyright (c) 2017 joshua stein <jcs@jcs.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

#
# helper methods
#

def device_from_bearer
  if m = request.env["HTTP_AUTHORIZATION"].to_s.match(/^Bearer (.+)/)
    token = m[1]
    if (d = Device.find_by_access_token(token))
      if d.token_expires_at >= Time.now
        return d
      end
    end
  end

  nil
end

def need_params(*ps)
  ps.each do |p|
    if params[p].to_s.blank?
      yield(p)
    end
  end
end

def validation_error(msg)
  [ 400, {
    "ValidationErrors" => { "" => [
      msg,
    ]},
    "Object" => "error",
  }.to_json ]
end

#
# begin sinatra routing
#

# import JSON params for every request
before do
  if request.content_type.to_s.match(/\Aapplication\/json(;|\z)/)
    js = request.body.read.to_s
    if !js.strip.blank?
      params.merge!(JSON.parse(js))
    end
  end

  # some bitwarden apps send params with uppercased first letter, some all
  # lowercase.  just standardize on all lowercase.
  params.keys.each do |k|
    params[k.downcase.to_sym] = params.delete(k)
  end

  # we're always going to reply with json
  content_type :json
end

namespace IDENTITY_BASE_URL do
  # depending on grant_type:
  #  password: login with a username/password, register/update the device
  #  refresh_token: just generate a new access_token
  # respond with an access_token and refresh_token
  post "/connect/token" do
    d = nil

    case params[:grant_type]
    when "refresh_token"
      need_params(:refresh_token) do |p|
        return validation_error("#{p} cannot be blank")
      end

      d = Device.find_by_refresh_token(params[:refresh_token])
      if !d
        return validation_error("Invalid refresh token")
      end

    when "password"
      need_params(
        :client_id,
        :grant_type,
        :deviceidentifier,
        :devicename,
        :devicetype,
        :password,
        :scope,
        :username,
      ) do |p|
        return validation_error("#{p} cannot be blank")
      end

      if params[:scope] != "api offline_access"
        return validation_error("scope not supported")
      end

      u = User.find_by_email(params[:username])
      if !u
        return validation_error("Invalid username")
      end

      if !u.has_password_hash?(params[:password])
        return validation_error("Invalid password")
      end

      if u.two_factor_enabled? &&
      (params[:twofactortoken].blank? ||
      !u.verifies_totp_code?(params[:twofactortoken]))
        return [ 400, {
          "error" => "invalid_grant",
          "error_description" => "Two factor required.",
          "TwoFactorProviders" => [ 0 ], # authenticator
          "TwoFactorProviders2" => { "0" => nil }
        }.to_json ]
      end

      d = Device.find_by_uuid(params[:deviceidentifier])
      if d && d.user_uuid != u.uuid
        # wat
        d.destroy
        d = nil
      end

      if !d
        d = Device.new
        d.user_uuid = u.uuid
        d.uuid = params[:deviceidentifier]
      end

      d.type = params[:devicetype]
      d.name = params[:devicename]
      if params[:devicepushtoken].present?
        d.push_token = params[:devicepushtoken]
      end
    else
      return validation_error("grant type not supported")
    end

    d.regenerate_tokens!

    User.transaction do
      if !d.save
        return validation_error("Unknown error")
      end

      {
        :access_token => d.access_token,
        :expires_in => (d.token_expires_at - Time.now).floor,
        :token_type => "Bearer",
        :refresh_token => d.refresh_token,
        :Key => d.user.key,
        # TODO: when to include :privateKey and :TwoFactorToken?
      }.to_json
    end
  end
end

namespace BASE_URL do
  # create a new user
  post "/accounts/register" do
    content_type :json

    if !ALLOW_SIGNUPS
      return validation_error("Signups are not permitted")
    end

    need_params(:masterpasswordhash) do |p|
      return validation_error("#{p} cannot be blank")
    end

    if !params[:email].to_s.match(/^.+@.+\..+$/)
      return validation_error("Invalid e-mail address")
    end

    if !params[:key].to_s.match(/^0\..+\|.+/)
      return validation_error("Invalid key")
    end

    begin
      Bitwarden::CipherString.parse(params[:key])
    rescue Bitwarden::InvalidCipherString
      return validation_error("Invalid key")
    end

    User.transaction do
      params[:email].downcase!

      if User.find_by_email(params[:email])
        return validation_error("E-mail is already in use")
      end

      u = User.new
      u.email = params[:email]
      u.password_hash = params[:masterpasswordhash]
      u.password_hint = params[:masterpasswordhint]
      u.key = params[:key]

      # is this supposed to come from somewhere?
      u.culture = "en-US"

      # i am a fair and just god
      u.premium = true

      if !u.save
        return validation_error("User save failed")
      end

      ""
    end
  end

  # fetch profile and ciphers
  get "/sync" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    {
      "Profile" => d.user.to_hash,
      "Folders" => d.user.folders.map{|f| f.to_hash },
      "Ciphers" => d.user.ciphers.map{|c| c.to_hash },
      "Domains" => {
        "EquivalentDomains" => nil,
        "GlobalEquivalentDomains" => [],
        "Object" => "domains",
      },
      "Object" => "sync",
    }.to_json
  end

  #
  # ciphers
  #

  # create a new cipher
  post "/ciphers" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    need_params(:type, :name) do |p|
      return validation_error("#{p} cannot be blank")
    end

    begin
      Bitwarden::CipherString.parse(params[:name])
    rescue Bitwarden::InvalidCipherString
      return validation_error("Invalid name")
    end

    if !params[:folderid].blank?
      if !Folder.find_by_user_uuid_and_uuid(d.user_uuid, params[:folderid])
        return validation_error("Invalid folder")
      end
    end

    c = Cipher.new
    c.user_uuid = d.user_uuid
    c.update_from_params(params)

    Cipher.transaction do
      if !c.save
        return validation_error("error saving")
      end

      c.to_hash.merge({
        "Edit" => true,
      }).to_json
    end
  end

  # update a cipher
  put "/ciphers/:uuid" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    c = nil
    if params[:uuid].blank? ||
    !(c = Cipher.find_by_user_uuid_and_uuid(d.user_uuid, params[:uuid]))
      return validation_error("invalid cipher")
    end

    need_params(:type, :name) do |p|
      return validation_error("#{p} cannot be blank")
    end

    begin
      Bitwarden::CipherString.parse(params[:name])
    rescue Bitwarden::InvalidCipherString
      return validation_error("Invalid name")
    end

    if !params[:folderid].blank?
      if !Folder.find_by_user_uuid_and_uuid(d.user_uuid, params[:folderid])
        return validation_error("Invalid folder")
      end
    end

    c.update_from_params(params)

    Cipher.transaction do
      if !c.save
        return validation_error("error saving")
      end

      c.to_hash.merge({
        "Edit" => true,
      }).to_json
    end
  end

  # delete a cipher
  delete "/ciphers/:uuid" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    c = nil
    if params[:uuid].blank? ||
    !(c = Cipher.find_by_user_uuid_and_uuid(d.user_uuid, params[:uuid]))
      return validation_error("invalid cipher")
    end

    c.destroy

    ""
  end

  #
  # folders
  #

  # create a new folder
  post "/folders" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    need_params(:name) do |p|
      return validation_error("#{p} cannot be blank")
    end

    begin
      Bitwarden::CipherString.parse(params[:name])
    rescue
      return validation_error("Invalid name")
    end

    f = Folder.new
    f.user_uuid = d.user_uuid
    f.update_from_params(params)

    Folder.transaction do
      if !f.save
        return validation_error("error saving")
      end

      f.to_hash.to_json
    end
  end

  # rename a folder
  put "/folders/:uuid" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    f = nil
    if params[:uuid].blank? ||
    !(f = Folder.find_by_user_uuid_and_uuid(d.user_uuid, params[:uuid]))
      return validation_error("invalid folder")
    end

    need_params(:name) do |p|
      return validation_error("#{p} cannot be blank")
    end

    begin
      Bitwarden::CipherString.parse(params[:name])
    rescue
      return validation_error("Invalid name")
    end

    f.update_from_params(params)

    Folder.transaction do
      if !f.save
        return validation_error("error saving")
      end

      f.to_hash.to_json
    end
  end

  # delete a folder
  delete "/folders/:uuid" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    f = nil
    if params[:uuid].blank? ||
    !(f = Folder.find_by_user_uuid_and_uuid(d.user_uuid, params[:uuid]))
      return validation_error("invalid folder")
    end

    f.destroy

    ""
  end

  #
  # device push tokens
  #

  put "/devices/identifier/:uuid/clear-token" do
    # XXX: for some reason, the iOS app doesn't send an Authorization header
    # for this
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    d.push_token = nil

    Device.transaction do
      if !d.save
        return validation_error("error saving")
      end

      ""
    end
  end

  put "/devices/identifier/:uuid/token" do
    d = device_from_bearer
    if !d
      return validation_error("invalid bearer")
    end

    d.push_token = params[:pushtoken]

    Device.transaction do
      if !d.save
        return validation_error("error saving")
      end

      ""
    end
  end
end

namespace ICONS_URL do
  get "/:domain/icon.png" do
    # TODO: do this service ourselves

    redirect "http://#{params[:domain]}/favicon.ico"
  end
end
