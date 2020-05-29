# frozen_string_literal: true

# Copyright, 2018, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'faraday'
require 'faraday/adapter'
require 'kernel/sync'
require 'async/http/internet'

require_relative 'agent'

module Async
	module HTTP
		module Faraday
			# Detect whether we can use persistent connections:
			PERSISTENT = ::Faraday::Connection.instance_methods.include?(:close)
			
			class Adapter < ::Faraday::Adapter
				CONNECTION_EXCEPTIONS = [
					Errno::EADDRNOTAVAIL,
					Errno::ECONNABORTED,
					Errno::ECONNREFUSED,
					Errno::ECONNRESET,
					Errno::EHOSTUNREACH,
					Errno::EINVAL,
					Errno::ENETUNREACH,
					Errno::EPIPE,
					IOError,
					SocketError
				].freeze

				def initialize(*arguments, **options, &block)
					super
					
					@clients = {}
					@persistent = PERSISTENT && options.fetch(:persistent, true)
					@timeout = options[:timeout]
				end
				
				def close
					clients = @clients.values
					@clients.clear
				
					clients.each(&:close)
				end
				
				def call(env)
					super
					
					parent = Async::Task.current?
					
					Sync do
						with_timeout do
							endpoint = Endpoint.parse(env[:url].to_s, ssl_context: ssl_context)
							key = host_key(endpoint)
				
							client = @clients.fetch(key) do
								@clients[key] = Client.new(endpoint)
							end
				
							body = Body::Buffered.wrap(env[:body] || [])
							headers = ::Protocol::HTTP::Headers[env[:request_headers]]
				
							request = ::Protocol::HTTP::Request.new(client.scheme, endpoint.authority, env[:method].to_s.upcase, endpoint.path, nil, headers, body)
				
							response = client.call(request)
							
							save_response(env, response.status, response.read, response.headers)
						end
					ensure
						# If we are the top level task, even if we are persistent, we must close the connection:
						if parent.nil? || !@persistent
							close
						end
					end
					
					return @app.call(env)
				rescue Errno::ETIMEDOUT, Async::TimeoutError => e
					raise ::Faraday::TimeoutError, e
				rescue OpenSSL::SSL::SSLError => e
					raise ::Faraday::SSLError, e
				rescue *CONNECTION_EXCEPTIONS => e
					raise ::Faraday::ConnectionFailed, e
				end

				private

				def with_timeout(task: Async::Task.current)
					if @timeout
						task.with_timeout(@timeout, ::Faraday::TimeoutError) do
							yield
						end
					else
						yield
					end
				end

				def host_key(endpoint)
					url = endpoint.url.dup
					
					url.path = ""
					url.fragment = nil
					url.query = nil
					
					return url
				end

				def ssl_context
					@ssl_context ||= OpenSSL::SSL::SSLContext.new.tap do |c|
						c.set_params(verify_mode: OpenSSL::SSL::VERIFY_NONE)
					end
				end
			end
		end
	end
end
