#!/usr/bin/node

const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');
const ami = new require('asterisk-manager')('5038', '127.0.0.1', 'asterisk', '881d6256664648e0ebe1ed0e9b1340f2', true);
const app = require('express')();
const redis = require("redis").createClient();

admin.initializeApp({
    credential: admin.credential.cert(require(path.join(__dirname, 'rbt-linhome-firebase-adminsdk-xx5ca-2d08c1fea5.json'))),
});

ami.keepConnected();

app.use(require('body-parser').urlencoded({ extended: true }));
app.listen(8082, '127.0.0.1');

function pushOk(token, result) {
    if (result && result.successCount && parseInt(result.successCount)) {
        console.log((new Date()).toLocaleString() + " ok: " + token);
    } else {
        pushFail(token, result);
    }
}

function pushFail(token, error) {
    console.log(error);

    console.log((new Date()).toLocaleString() + " err: " + token);

    let broken = false;
    if (error && error.results && error.results.length && error.results[0] && error.results[0].error && error.results[0].error.code) {
        if (error.results[0].error.code == 'messaging/registration-token-not-registered') {
            for (let i in contacts) {
                if (contacts[i] == token) {
                    delete contacts[i];
                    redis.set('contacts', JSON.stringify(contacts));
                }
            }
            broken = true;
        }
    }

    if (!broken) {
        fs.appendFileSync('/tmp/pushFail.log', (new Date()).toLocaleString() + " err: " + token + "\n" + JSON.stringify(error) + "\n\n");
    }
}

function realPush(msg, data, options, token, type) {

    console.log(token, type, msg, data, options);

    let message = {
        notification: msg,
        data: data,
    };

    if (options) {
        admin.messaging().sendToDevice(token, message, options).then(r => {
            pushOk(token, r);
        }).catch(e => {
            pushFail(token, e);
        });
    } else {
        admin.messaging().sendToDevice(token, message).then(r => {
            pushOk(token, r);
        }).catch(e => {
            pushFail(token, e);
        });
    }
}

var contacts = {};

ami.on('contactstatus', e => {
    if (e.aor) {
        let uri = e.uri.split(';');
        let token;
        let type;
        for (let i = 0; i < uri.length; i++) {
            let p = uri[i].split('=');
            switch (p[0]) {
                case 'pn-tok':
                    token = p[1];
                    break;
                case 'pn-type':
                    type = p[1];
                    break;
                case 'pn-prid':
                    token = p[1];
                    break;
                case 'pn-provider':
                    type = p[1];
                    break;
            }
        }
        if (token && (type === 'firebase' || type === 'fcm')) {
            contacts[e.aor] = token;
            console.log(e.aor, token);
            redis.set('contacts', JSON.stringify(contacts));
        }
    }
});

app.get('/wakeup', function (req, res) {
    console.log(req.query);
    if (req.query.ext && contacts[req.query.ext]) {
        realPush({
                // empty message
            }, {
                type: 'voip',
                realm: req.query.realm?req.query.realm:'Unknown',
                user: req.query.from?req.query.from:'Unknown',
            }, {
                priority: 'high',
                mutableContent: true,
            },
            contacts[req.query.ext],
            0
        );
    }
    res.status(204).send();
});

redis.get('contacts', (e, v) => {
    if (!e && v) {
        contacts = JSON.parse(v);
        console.log(contacts);
    }
});
