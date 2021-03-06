express = require('express')
app = express()
server = require('http').createServer(app)
io = require('socket.io')(server)
stylus = require('stylus')
config = require('./config')
mongoskin = require('mongoskin')
MongoStore = require('connect-mongo')(express)
crypto = require('crypto')
bcrypt = require('bcrypt')
passport = require('passport')
localStrategy = require('passport-local').Strategy
jwt = require('jsonwebtoken')
zmq = require('zmq')
cors = require('cors')
async = require('async');
nodemailer = require('nodemailer');
moment = require('moment');

# MongoDB connection
appName = 'netrunner'
mongoUrl = process.env['MONGO_URL'] || "mongodb://127.0.0.1:27017/netrunner"
db = mongoskin.db(mongoUrl)

# Game lobby
gameid = 0
games = {}
lobbyUpdate = false

swapSide = (side) ->
  if side is "Corp" then "Runner" else "Corp"

refreshLobby = () ->
  lobbyUpdate = true

removePlayer = (socket) ->
  game = games[socket.gameid]
  if game
    for player, i in game.players
      if player.id is socket.id
        game.players.splice(i, 1)
        break
    for spectator, i in game.spectators
      if spectator.id is socket.id
        game.spectators.splice(i, 1)
        break
    if game.players.length is 0 and game.spectators.length is 0
      delete games[socket.gameid]
      requester.send(JSON.stringify({action: "remove", gameid: socket.gameid}))
    socket.leave(socket.gameid)
    socket.gameid = false
    refreshLobby()
  for k, v of games
    delete games[k] if v.players.length < 2 and (new Date() - v.date) > 3600000

joinGame = (socket, gameid) ->
  game = games[gameid]
  if game and game.players.length < 2
    side = if game.players.length is 1 then swapSide(game.players[0].side) else "Corp"
    game.players.push({user: socket.request.user, id: socket.id, side: side})
    socket.join(gameid)
    socket.gameid = gameid
    socket.emit("netrunner", {type: "game", gameid: gameid})
    refreshLobby()

getUsername = (socket) ->
  ((socket.request || {}).user || {}).username

# ZeroMQ
clojure_hostname = process.env['CLOJURE_HOST'] || "127.0.0.1"
requester = zmq.socket('req')
requester.connect("tcp://#{clojure_hostname}:1043")
requester.on 'message', (data) ->
  response = JSON.parse(data)
  unless response is "ok"
    lobby.to(response.gameid).emit("netrunner", {type: response.action, state: response})

# Socket.io
io.set("heartbeat timeout", 30000)
io.use (socket, next) ->
  if socket.handshake.query.token
    jwt.verify socket.handshake.query.token, config.salt, (err, user) ->
      socket.request.user = user unless err
  next()

chat = io.of('/chat').on 'connection', (socket) ->
  socket.on 'netrunner', (msg) ->
    msg.date = new Date()
    chat.emit('netrunner', msg)
    db.collection('messages').insert msg, (err, result) ->

lobby = io.of('/lobby').on 'connection', (socket) ->
  refreshLobby()

  socket.on 'disconnect', () ->
    gid = socket.gameid
    game = games[gid]
    if game
      if game.started and game.players.length > 1
        requester.send(JSON.stringify({action: "notification", gameid: gid, text: "#{getUsername(socket)} disconnected."}))
      removePlayer(socket)

  socket.on 'netrunner', (msg) ->
    switch msg.action
      when "create"
        game = {date: new Date(), gameid: ++gameid, title: msg.title, allowspectator: msg.allowspectator,\
                players: [{user: socket.request.user, id: socket.id, side: "Corp"}], spectators: []}
        games[gameid] = game
        socket.join(gameid)
        socket.gameid = gameid
        socket.emit("netrunner", {type: "game", gameid: gameid})
        refreshLobby()

      when "leave-lobby"
        gid = socket.gameid
        removePlayer(socket)
        if socket.request.user
          socket.broadcast.to(gid).emit('netrunner', {type: "say", user: "__system__", text: "#{getUsername(socket)} left the game."})

      when "leave-game"
        gid = socket.gameid
        game = games[gid]
        if game
          if game.players.length > 1
            requester.send(JSON.stringify({action: "notification", gameid: gid, text: "#{getUsername(socket)} left the game."}))
          removePlayer(socket)

      when "join"
        joinGame(socket, msg.gameid)
        socket.broadcast.to(msg.gameid).emit 'netrunner',
          type: "say"
          user: "__system__"
          notification: "ting"
          text: "#{getUsername(socket)} joined the game."

      when "watch"
        game = games[msg.gameid]
        if game
          game.spectators.push({user: socket.request.user, id: socket.id})
          socket.join(msg.gameid)
          socket.gameid = msg.gameid
          socket.emit("netrunner", {type: "game", gameid: msg.gameid, started: game.started})
          refreshLobby()
          if game.started
            requester.send(JSON.stringify({action: "notification", gameid: msg.gameid, text: "#{getUsername(socket)} joined the game as a spectator."}))
          else
            socket.broadcast.to(msg.gameid).emit 'netrunner',
              type: "say"
              user: "__system__"
              text: "#{getUsername(socket)} joined the game as a spectator."

      when "reconnect"
        game = games[msg.gameid]
        if game and game.started
          joinGame(socket, msg.gameid)
          requester.send(JSON.stringify({action: "notification", gameid: socket.gameid, text: "#{getUsername(socket)} reconnected."}))

      when "say"
        lobby.to(msg.gameid).emit("netrunner", {type: "say", user: socket.request.user, text: msg.text})

      when "swap"
        for player in games[socket.gameid].players
          player.side = swapSide(player.side)
          player.deck = null
        lobby.to(msg.gameid).emit('netrunner', {type: "games", games: games})

      when "deck"
        for player in games[socket.gameid].players
          if player.user.username is getUsername(socket)
            player.deck = msg.deck
            break
        lobby.to(msg.gameid).emit('netrunner', {type: "games", games: games})

      when "start"
        game = games[socket.gameid]
        if game
          game.started = true
          msg = games[socket.gameid]
          msg.action = "start"
          msg.gameid = socket.gameid
          requester.send(JSON.stringify(msg))
          for player in game.players
            delete player["deck"]
          refreshLobby()

      when "do"
        try
          requester.send(JSON.stringify(msg))
        catch err
          console.log(err)

sendLobby = () ->
  if lobby and lobbyUpdate
    lobby.emit('netrunner', {type: "games", games: games})
    lobbyUpdate = false

setInterval(sendLobby, 1000)

# Express config
app.configure ->
  app.use express.favicon(__dirname + "/resources/public/img/jinteki.ico")
  app.set 'port', 1042
  app.set 'ipaddr', "0.0.0.0"
  app.use express.methodOverride() # provide PUT DELETE
  app.use express.cookieParser()
  app.use express.urlencoded()
  app.use express.json()
  app.use express.session
    store: new MongoStore(url: mongoUrl)
    secret: config.salt
    cookie: { maxAge: 2592000000 } # 30 days
  app.use passport.initialize()
  app.use passport.session()
  app.use stylus.middleware({src: __dirname + '/src', dest: __dirname + '/resources/public'})
  app.use express.static(__dirname + '/resources/public')
  app.use app.router

# Auth
passport.use new localStrategy (username, password, done) ->
  db.collection('users').findOne {username: RegExp("^#{username}$", "i")}, (err, user) ->
    return done(err) if err or not user
    bcrypt.compare password, user.password, (err, valid) ->
    	return done(err) if err
    	return done(null, false) if not valid
    	done(null, {username: user.username, emailhash: user.emailhash, _id: user._id})

passport.serializeUser (user, done) ->
  done(null, user._id) if user

passport.deserializeUser (id, done) ->
  db.collection('users').findById id, (err, user) ->
    console.log err if err
    done(err, {username: user.username, emailhash: user.emailhash, _id: user._id, special: user.special})

# Routes
app.options('*', cors())

app.post '/login', passport.authenticate('local'), (req, res) ->
  db.collection('users').update {username: req.user.username}, {$set: {lastConnection: new Date()}}, (err) ->
    throw err if err
    res.json(200, {user: req.user})

app.get '/logout', (req, res) ->
  req.logout()
  res.redirect('/')

app.post '/register', (req, res) ->
  db.collection('users').findOne username: req.body.username, (err, user) ->
    if user
      res.send {message: 'Username taken'}, 422
    else
      email = req.body.email.trim().toLowerCase()
      req.body.emailhash = crypto.createHash('md5').update(email).digest('hex')
      req.body.registrationDate = new Date()
      req.body.lastConnection = new Date()
      bcrypt.hash req.body.password, 3, (err, hash) ->
        req.body.password = hash
        db.collection('users').insert req.body, (err) ->
          res.send "error: #{err}" if err
          req.login req.body, (err) -> next(err) if err
          db.collection('decks').find({username: '__demo__'}).toArray (err, demoDecks) ->
            throw err if err
            for deck in demoDecks
              delete deck._id
              deck.username = req.body.username
            if demoDecks.length > 0
              db.collection('decks').insert demoDecks, (err, newDecks) ->
                throw err if err
                res.json(200, {user: req.user, decks: newDecks})
            else
              res.json(200, {user: req.user, decks: []})

app.post '/forgot', (req, res) ->
  async.waterfall [
    (done) ->
      crypto.randomBytes 20, (err, buf) ->
        token = buf.toString('hex')
        done(err, token)
    (token, done) ->
      db.collection('users').findOne { email: req.body.email }, (err, user) ->
        if (!user)
          res.send {message: 'No account with that email address exists.'}, 421
        else
          # 1 hour expiration
          resetPasswordToken = token
          resetPasswordExpires = Date.now() + 3600000

          db.collection('users').update { email: req.body.email }, {$set: {resetPasswordToken: resetPasswordToken, resetPasswordExpires: resetPasswordExpires}}, (err) ->
            throw err if err
            done(err, token, user)
#            res.send {message: 'Password reset sent.'}, 200
    (token, user, done) ->
      smtpTransport = nodemailer.createTransport {
        service: 'SendGrid',
        auth: {
          user: 'jinteki-user',
          pass: 'jinteki-user1'
        }
      }
      mailOptions = {
        from: 'support@jinteki.net',
        to: user.email,
        subject: 'Jinteki Password Reset',
        text: 'You are receiving this because you (or someone else) have requested the reset of the password for your account.\n\n' +
          'Please click on the following link, or paste this into your browser to complete the process:\n\n' +
          'http://' + req.headers.host + '/reset/' + token + '\n\n' +
          'If you did not request this, please ignore this email and your password will remain unchanged.\n'
      }
      smtpTransport.sendMail mailOptions, (err, response) ->
        throw err if err
        res.send {message: 'An e-mail has been sent to ' + user.email + ' with further instructions.'}, 200 
  ]

app.get '/check/:username', (req, res) ->
  db.collection('users').findOne username: req.params.username, (err, user) ->
    if user
      res.send {message: 'Username taken'}, 422
    else
      res.send {message: 'OK'}, 200

app.get '/reset/:token', (req, res) ->
  db.collection('users').findOne resetPasswordToken: req.params.token, resetPasswordExpires: { $gt: Date.now() } , (err, user) ->
    if (!user)
      #req.flash 'error', 'Password reset token is invalid or has expired.'
      return res.redirect '/forgot'
    if user
      db.collection('users').update {username: user.username}, {$set: {lastConnection: new Date()}}, (err) ->
      token = jwt.sign(user, config.salt, {expiresInMinutes: 360})
    res.render 'reset.jade', { user: req.user }

app.post '/reset/:token', (req, res) ->
  async.waterfall [
    (done) ->
      db.collection('users').findOne resetPasswordToken: req.params.token, resetPasswordExpires: { $gt: Date.now() }, (err, user) ->
        if (!user)
          # req.flash('error', 'Password reset token is invalid or has expired.');
          return res.redirect('back');

        # To be implemented: checking password == confirm 
        #if (req.body.password != req.body.confirm)
        #  res.send {message: 'Password does not match Confirm'}, 412

        bcrypt.hash req.body.password, 3, (err, hash) ->
          password = hash
          resetPasswordToken = undefined;
          resetPasswordExpires = undefined

          db.collection('users').update { username: user.username }, {$set: {password: password, resetPasswordToken: resetPasswordToken, resetPasswordExpires: resetPasswordExpires}}, (err) ->
            req.logIn user, (err) ->
              done(err, user)
    (user, done) ->
      smtpTransport = nodemailer.createTransport {
        service: 'SendGrid',
        auth: {
          user: 'jinteki-user',
          pass: 'jinteki-user1'
        }
      }
      mailOptions = {
        to: user.email,
        from: 'passwordreset@jinteki.net',
        subject: 'Your password has been changed',
        text: 'Hello,\n\n' +
          'This is a confirmation that the password for your account ' + user.email + ' has just been changed.\n'
      }
      smtpTransport.sendMail mailOptions, (err) ->
        #req.flash 'success', 'Success! Your password has been changed.'
        throw err if err
        done(err)
  ], (err) ->
    throw err if err
    res.redirect('/')

app.get '/messages/:channel', (req, res) ->
  db.collection('messages').find({channel: req.params.channel}).sort(date: -1).limit(100).toArray (err, data) ->
    throw err if err
    res.json(200, data.reverse())

app.get '/data/decks', (req, res) ->
  if req.user
    db.collection('decks').find({username: req.user.username}).toArray (err, data) ->
      throw err if err
      res.json(200, data)
  else
    db.collection('decks').find({username: "__demo__"}).toArray (err, data) ->
      throw err if err
      delete deck._id for deck in data
      res.json(200, data)

app.post '/data/decks', (req, res) ->
  deck = req.body
  if req.user
    deck.username = req.user.username
    if deck._id
      id = deck._id
      delete deck._id
      db.collection('decks').update {_id: mongoskin.helper.toObjectID(id)}, deck, (err) ->
        console.log(err) if err
        res.send {message: 'OK'}, 200
    else
      db.collection('decks').insert deck, (err, data) ->
        console.log(err) if err
        res.json(200, data[0])
  else
    res.send {message: 'Unauthorized'}, 401

app.post '/data/decks/delete', (req, res) ->
  deck = req.body
  if req.user
    db.collection('decks').remove {_id: mongoskin.helper.toObjectID(deck._id), username: req.user.username}, (err) ->
      res.send {message: 'OK'}, 200
  else
    res.send {message: 'Unauthorized'}, 401

app.get '/data/donators', (req, res) ->
  db.collection('donators').find({}).sort({amount: -1}).toArray (err, data) ->
    res.json(200, (d.username or d.name for d in data))

app.get '/data/news', (req, res) ->
  db.collection('news').find().sort({_id: -1}).toArray (err, data) ->
    for d in data
      d.date = moment(d._id.getTimestamp().toISOString()).format("MM/DD/YYYY HH:mm a");
      delete d._id
    res.json(200, data)

app.get '/data/:collection', (req, res) ->
  db.collection(req.params.collection).find().sort(_id: 1).toArray (err, data) ->
    throw err if err
    delete d._id for d in data
    res.json(200, data)

app.get '/data/:collection/:field/:value', (req, res) ->
  filter = {}
  filter[req.params.field] = req.params.value
  db.collection(req.params.collection).find(filter).toArray (err, data) ->
    console.error(err) if err
    delete d._id for d in data
    res.json(200, data)

app.configure 'development', ->
  console.log "Dev environment"
  app.get '/*', (req, res) ->
    if req.user
      db.collection('users').update {username: req.user.username}, {$set: {lastConnection: new Date()}}, (err) ->
      token = jwt.sign(req.user, config.salt)
    res.render('index.jade', { user: req.user, env: 'dev', token: token})

app.configure 'production', ->
  console.log "Prod environment"
  app.get '/*', (req, res) ->
    if req.user
      db.collection('users').update {username: req.user.username}, {$set: {lastConnection: new Date()}}, (err) ->
      token = jwt.sign(req.user, config.salt, {expiresInMinutes: 360})
    res.render('index.jade', { user: req.user, env: 'prod', token: token})

# Server
terminate = () ->
  process.exit(1)
  console.log("#{Date(Date.now())}: Node server stopped.")

process.on('exit', terminate)

for signal in ['SIGHUP', 'SIGINT', 'SIGQUIT', 'SIGILL', 'SIGTRAP', 'SIGABRT',
               'SIGBUS', 'SIGFPE', 'SIGUSR1', 'SIGSEGV', 'SIGUSR2', 'SIGTERM']
  process.on(signal, terminate)

process.on 'uncaughtException', (err) ->
  console.log(err.stack)

server.listen app.get('port'), app.get('ipaddr'), ->
  console.log(new Date().toString() + ": Express server listening on port " + app.get('port'))
