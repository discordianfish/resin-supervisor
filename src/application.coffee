_ = require 'lodash'
es = require 'event-stream'
url = require 'url'
knex = require './db'
path = require 'path'
config = require './config'
Docker = require 'dockerode'
PUBNUB = require 'pubnub'
Promise = require 'bluebird'
JSONStream = require 'JSONStream'
PlatformAPI = require 'resin-platform-api/request'

DOCKER_SOCKET = '/run/docker.sock'
PLATFORM_ENDPOINT = url.resolve(config.apiEndpoint, '/ewa/')
resinAPI = new PlatformAPI(PLATFORM_ENDPOINT)

docker = Promise.promisifyAll(new Docker(socketPath: DOCKER_SOCKET))
# Hack dockerode to promisify internal classes' prototypes
Promise.promisifyAll(docker.getImage().__proto__)
Promise.promisifyAll(docker.getContainer().__proto__)

pubnub = PUBNUB.init(config.pubnub)

publish = null

knex('config').select('value').where(key: 'uuid').then ([uuid]) ->
	uuid = uuid.value
	channel = "device-#{uuid}-logs"

	publish = (message) ->
		pubnub.publish({channel, message})

exports.kill = kill = (app) ->
	docker.listContainersAsync(all: 1)
	.then (containers) ->
		Promise.all(
			containers
			.filter (container) -> container.Image is "#{app.imageId}:latest"
			.map (container) -> docker.getContainer(container.Id)
			.map (container) ->
				console.log("Stopping and deleting container:", container)
				container.stopAsync()
				.then ->
					container.removeAsync()
		)

exports.start = start = (app) ->
	docker.getImage(app.imageId).inspectAsync()
	.catch (error) ->
		console.log("Pulling image:", app.imageId)
		docker.createImageAsync(fromImage: app.imageId)
		.then (stream) ->
			return new Promise (resolve, reject) ->
				if stream.headers['content-type'] is 'application/json'
					stream.pipe(JSONStream.parse('error'))
					.pipe(es.mapSync(reject))
				else
					stream.pipe(es.wait((error, text) -> reject(text)))

				stream.on('end', resolve)
	.then ->
		console.log("Creating container:", app.imageId)
		ports = {}
		# Parse the env vars before trying to access them, that's because they have to be stringified for knex..
		env = JSON.parse(app.env)
		if env.PORT?
			maybePort = parseInt(env.PORT, 10)
			if parseFloat(env.PORT) is maybePort and maybePort > 0 and maybePort < 65535
				port = maybePort
		if port?
			ports[port + '/tcp'] = {}
		docker.createContainerAsync(
			Image: app.imageId
			Cmd: ['/bin/bash', '-c', '/start']
			Tty: true
			Volumes:
				'/dev': {}
			Env: _.map env, (v, k) -> k + '=' + v
			ExposedPorts: ports
		)
		.then (container) ->
			console.log('Starting container:', app.imageId)
			ports = {}
			if port?
				ports[port + '/tcp'] = [ HostPort: String(port) ]
			container.startAsync(
				Privileged: true
				PortBindings: ports
				Binds: [
					'/dev:/dev'
					'/var/run/docker.sock:/run/docker.sock'
				]
			)
			.then ->
				container.attach {stream: true, stdout: true, stderr: true, tty: true}, (err, stream) ->
					es.pipeline(
						stream
						es.split()
						# Remove color escape sequences
						es.mapSync((s) -> s.replace(/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]/g, ''))
						es.mapSync(publish)
					)
	.tap ->
		console.log('Started container:', app.imageId)

exports.restart = restart = (app) ->
	kill(app)
	.then ->
		start(app)

# 0 - Idle
# 1 - Updating
# 2 - Update required
currentlyUpdating = 0
exports.update = ->
	if currentlyUpdating isnt 0
		# Mark an update required after the current.
		currentlyUpdating = 2
		return
	currentlyUpdating = 1
	Promise.all([
		knex('config').select('value').where(key: 'apiKey')
		knex('config').select('value').where(key: 'uuid')
		knex('app').select()
	])
	.then ([[apiKey], [uuid], apps]) ->
		apiKey = apiKey.value
		uuid = uuid.value
		resinAPI.get(
			resource: 'application'
			options:
				expand: 'environment_variable'
				filter:
					'device/uuid': uuid
			customOptions:
				apikey: apiKey
		)
		.then (remoteApps) ->
			console.log("Remote apps")
			remoteApps = _.filter(remoteApps, 'commit')
			remoteApps = _.map remoteApps, (app) ->
				env = {}
				if app.environment_variable?
					for envVar in app.environment_variable
						env[envVar.name] = envVar.value
				return {
					imageId: "#{process.env.REGISTRY_ENDPOINT}/#{path.basename(app.git_repository, '.git')}/#{app.commit}"
					env: JSON.stringify(env) # The env has to be stored as a JSON string for knex
				}

			remoteApps = _.indexBy(remoteApps, 'imageId')
			remoteImages = _.keys(remoteApps)
			console.log(remoteImages)

			console.log("Local apps")
			apps = _.map(apps, (app) -> _.pick(app, ['imageId', 'env']))
			apps = _.indexBy(apps, 'imageId')
			localImages = _.keys(apps)
			console.log(localImages)

			console.log("Apps to be removed")
			toBeRemoved = _.difference(localImages, remoteImages)
			console.log(toBeRemoved)

			console.log("Apps to be installed")
			toBeInstalled = _.difference(remoteImages, localImages)
			console.log(toBeInstalled)

			console.log("Apps to be updated")
			toBeUpdated = _.intersection(remoteImages, localImages)
			toBeUpdated = _.filter toBeUpdated, (imageId) ->
				return !_.isEqual(remoteApps[imageId], apps[imageId])
			console.log(toBeUpdated)

			# Delete all the ones to remove in one go
			Promise.map toBeRemoved, (imageId) ->
				kill(apps[imageId])
				.then ->
					knex('app').where('imageId', imageId).delete()
			.then ->
				# Then install the apps and add each to the db as they succeed
				installingPromises = toBeInstalled.map (imageId) ->
					app = remoteApps[imageId]
					start(app)
					.then ->
						knex('app').insert(app)
				# And restart updated apps and update db as they succeed
				updatingPromises = toBeUpdated.map (imageId) ->
					app = remoteApps[imageId]
					restart(app)
					.then ->
						knex('app').update(app).where(imageId: app.imageId)
				Promise.all(installingPromises.concat(updatingPromises))
	.finally ->
		if currentlyUpdating is 2
			# If an update is required then schedule it
			setTimeout(exports.update)
		# Set the updating as finished
		currentlyUpdating = 0
