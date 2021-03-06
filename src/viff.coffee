mr = require 'Mr.Async'
_ = require 'underscore'
Canvas = require 'canvas'
util = require 'util'
{EventEmitter} = require 'events'

webdriver = require 'selenium-webdriver'
Comparison = require './comparison'
Testcase = require './testcase'
Capability = require './capability'

webdriver.promise.controlFlow().on 'uncaughtException', (e) -> 
  console.error 'Unhandled error: ' + e

class Viff extends EventEmitter
  constructor: (seleniumHost) ->
    EventEmitter.call @

    @builder = new webdriver.Builder().usingServer(seleniumHost)
    @drivers = {}

  takeScreenshot: (capability, host, url, callback) -> 
    that = @
    defer = mr.Deferred().done(callback)

    capability = new Capability capability

    unless driver = @drivers[capability.key()]
      @builder = @builder.withCapabilities capability
      driver = @builder.build()
      @drivers[capability.key()] = driver

    [parsedUrl, selector, preHandle] = Testcase.parseUrl url

    driver.get host + parsedUrl
    preHandle driver, webdriver if _.isFunction preHandle

    driver.call( ->
      driver.takeScreenshot().then (base64Img) -> 
        if _.isString selector
          Viff.dealWithPartial base64Img, driver, selector, (partialImgBuffer) ->
            defer.resolve partialImgBuffer, null
        else
          defer.resolve new Buffer(base64Img, 'base64'), null

      return
    ).addErrback (ex) ->
      defer.resolve '', ex

    defer.promise()

  @constructCases: (capabilities, envHosts, links) ->
    cases = []
    _.each links, (url) ->
      _.each capabilities, (capability) ->

        if _.isArray capability
          [capabilityFrom, capabilityTo] = capability

          _.each envHosts, (host, envName) ->
            cases.push new Testcase(capabilityFrom, capabilityTo, host, host, envName, envName, url)
        else
          [[from, envFromHost], [to, envToHost]] = _.pairs envHosts
          cases.push new Testcase(capability, capability, envFromHost, envToHost, from, to, url)

    cases

  run: (cases, callback) ->
    defer = mr.Deferred().done callback
    that = this

    @emit 'before', cases
    start = Date.now()

    mr.asynEach(cases, (_case) ->
      iterator = this
      startcase = Date.now()

      that.emit 'beforeEach', _case, 0
      that.takeScreenshot _case.from.capability, _case.from.host, _case.url, (fromImage, fromImgEx) ->
        that.takeScreenshot _case.to.capability, _case.to.host, _case.url, (toImage, toImgEx) ->

          if fromImgEx isnt null or toImgEx isnt null
            that.emit 'afterEach', _case, 0, fromImgEx, toImgEx
            iterator.next()
          else 
            imgWithEnvs = _.object [[_case.from.capability.key() + '-' + _case.from.name, fromImage], [_case.to.capability.key() + '-' + _case.to.name, toImage]]
            comparison = new Comparison imgWithEnvs
            
            comparison.diff (diffImg) ->
              _case.result = comparison
              that.emit 'afterEach', _case, Date.now() - startcase

              iterator.next()
    , -> 
      endTime = Date.now() - start
      that.closeDrivers()
      that.emit 'after', cases, endTime

      defer.resolve cases, endTime
    ).start()

    defer.promise()

  closeDrivers: () ->
    @drivers[browser].quit() for browser of @drivers

  @dealWithPartial: (base64Img, driver, selector, callback) ->
    defer = mr.Deferred().done callback

    driver.findElement(webdriver.By.css(selector)).then (elem) ->
      elem.getLocation().then (location) ->
        elem.getSize().then (size) ->
          cvs = new Canvas(size.width, size.height)
          ctx = cvs.getContext '2d'
          img = new Canvas.Image
          img.src = new Buffer base64Img, 'base64'
          ctx.drawImage img, location.x, location.y, size.width, size.height, 0, 0, size.width, size.height

          defer.resolve cvs.toBuffer()

    defer.promise()

module.exports = Viff