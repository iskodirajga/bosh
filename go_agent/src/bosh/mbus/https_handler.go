package mbus

import (
	bosherr "bosh/errors"
	boshhttps "bosh/https_dispatcher"
	boshlog "bosh/logger"
	"encoding/base64"
	"errors"
	"io/ioutil"
	"net/http"
	"net/url"
)

type httpsHandler struct {
	parsedURL  *url.URL
	logger     boshlog.Logger
	dispatcher boshhttps.HttpsDispatcher
}

func newHttpsHandler(parsedURL *url.URL, logger boshlog.Logger) (handler httpsHandler) {
	handler.parsedURL = parsedURL
	handler.logger = logger
	handler.dispatcher = boshhttps.NewHttpsDispatcher(parsedURL, logger)

	return
}

func (h httpsHandler) Run(handlerFunc HandlerFunc) (err error) {
	err = h.Start(handlerFunc)
	if err != nil {
		err = bosherr.WrapError(err, "Starting https handler")
		return
	}
	return
}

func (h httpsHandler) Start(handlerFunc HandlerFunc) (err error) {
	agentHandler := func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			err = bosherr.WrapError(errors.New("URL or Method not found"), "Handle HTTP")
			w.WriteHeader(404)
			return
		}

		if h.requestNotAuthorized(r) {
			err = bosherr.WrapError(errors.New("Incorrect Basic Auth"), "Handle HTTP")
			w.Header().Add("WWW-Authenticate", `Basic realm=""`)
			w.WriteHeader(401)
			return
		}

		rawJSONPayload, err := ioutil.ReadAll(r.Body)
		if err != nil {
			err = bosherr.WrapError(err, "Reading http body")
			return
		}
		respBytes, _, err := performHandlerWithJSON(rawJSONPayload, handlerFunc, h.logger)
		if err != nil {
			err = bosherr.WrapError(err, "Running handler in a nice JSON sandwhich")
			return
		}
		w.Write(respBytes)
	}

	h.dispatcher.AddRoute("/agent", agentHandler)
	h.dispatcher.Start()

	return
}

func (h httpsHandler) Stop() {
	h.dispatcher.Stop()
	return
}

func (h httpsHandler) SendToHealthManager(topic string, payload interface{}) (err error) {
	return
}

func (h httpsHandler) requestNotAuthorized(request *http.Request) bool {
	username := h.parsedURL.User.Username()
	password, _ := h.parsedURL.User.Password()
	auth := username + ":" + password
	expectedAuthorizationHeader := "Basic " + base64.StdEncoding.EncodeToString([]byte(auth))

	return expectedAuthorizationHeader != request.Header.Get("Authorization")
}

// Utils:

type concreteHTTPHandler struct {
	Callback func(http.ResponseWriter, *http.Request)
}

func (e concreteHTTPHandler) ServeHTTP(rw http.ResponseWriter, r *http.Request) { e.Callback(rw, r) }
