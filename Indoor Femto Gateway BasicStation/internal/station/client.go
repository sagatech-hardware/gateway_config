package station

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Client is a BasicStation-side connection to an LNS. Callbacks fire from the
// read loop; Send is safe for concurrent use.
type Client struct {
	uri      string
	routerID string
	model    string
	conn     *websocket.Conn
	sendCh   chan []byte
	cancel   context.CancelFunc
	wg       sync.WaitGroup

	OnRouterConfig func(*RouterConfig)
	OnDnmsg        func(*Dnmsg)
}

// TLSFromPEM builds an mTLS config from PEM tc.* material. An empty trust uses
// the host system roots.
func TLSFromPEM(trust, cert, key string) (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if trust != "" {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM([]byte(trust)) {
			return nil, errors.New("tc.trust PEM invalid")
		}
		cfg.RootCAs = pool
	}
	if cert != "" && key != "" {
		pair, err := tls.X509KeyPair([]byte(cert), []byte(key))
		if err != nil {
			return nil, fmt.Errorf("tc.crt/tc.key: %w", err)
		}
		cfg.Certificates = []tls.Certificate{pair}
	}
	return cfg, nil
}

// Dial connects to the LNS, sends the version handshake, and starts the read
// and write loops. Call Close to stop.
func Dial(ctx context.Context, uri string, tlsCfg *tls.Config, routerID, model string) (*Client, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("parse LNS uri: %w", err)
	}
	if u.Scheme != "wss" && u.Scheme != "ws" {
		return nil, fmt.Errorf("LNS uri scheme %q not ws/wss", u.Scheme)
	}
	dialer := &websocket.Dialer{TLSClientConfig: tlsCfg, HandshakeTimeout: 15 * time.Second}
	conn, resp, err := dialer.DialContext(ctx, uri, http.Header{})
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("dial %s: %w (http %d)", uri, err, resp.StatusCode)
		}
		return nil, fmt.Errorf("dial %s: %w", uri, err)
	}
	c := &Client{uri: uri, routerID: routerID, model: model, conn: conn, sendCh: make(chan []byte, 64)}
	if err := c.sendVersion(); err != nil {
		conn.Close()
		return nil, err
	}
	runCtx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	c.wg.Add(2)
	go c.readLoop(runCtx)
	go c.writeLoop(runCtx)
	log.Printf("station: connected to %s", uri)
	return c, nil
}

func (c *Client) sendVersion() error {
	msg, _ := json.Marshal(map[string]any{
		"msgtype":  "version",
		"station":  c.model,
		"firmware": "pktfwd-station-bridge",
		"package":  "pktfwd-station-bridge",
		"model":    c.model,
		"protocol": 2,
		"features": "prod",
	})
	return c.conn.WriteMessage(websocket.TextMessage, msg)
}

// Send marshals and queues a BasicStation message (updf/jreq). It drops the
// message (with a log) if the send buffer is full, rather than blocking the
// uplink path.
func (c *Client) Send(msg any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	select {
	case c.sendCh <- data:
		return nil
	default:
		log.Printf("station: send buffer full, dropping %d bytes", len(data))
		return errors.New("send buffer full")
	}
}

func (c *Client) writeLoop(ctx context.Context) {
	defer c.wg.Done()
	for {
		select {
		case <-ctx.Done():
			return
		case data := <-c.sendCh:
			if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
				log.Printf("station: write: %v", err)
				return
			}
		}
	}
}

func (c *Client) readLoop(ctx context.Context) {
	defer c.wg.Done()
	defer c.conn.Close()
	for {
		if ctx.Err() != nil {
			return
		}
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("station: read: %v", err)
			}
			return
		}
		c.dispatch(data)
	}
}

func (c *Client) dispatch(data []byte) {
	var head struct {
		MsgType string `json:"msgtype"`
	}
	if err := json.Unmarshal(data, &head); err != nil {
		return
	}
	switch head.MsgType {
	case "router_config":
		var rc RouterConfig
		if json.Unmarshal(data, &rc) == nil && c.OnRouterConfig != nil {
			c.OnRouterConfig(&rc)
		}
	case "dnmsg", "dnframe":
		var dn Dnmsg
		if json.Unmarshal(data, &dn) == nil && c.OnDnmsg != nil {
			c.OnDnmsg(&dn)
		}
	default:
		log.Printf("station: recv %s", head.MsgType)
	}
}

// Close stops the loops and closes the connection.
func (c *Client) Close() {
	if c.cancel != nil {
		c.cancel()
	}
	_ = c.conn.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, "bye"),
		time.Now().Add(2*time.Second))
	_ = c.conn.Close()
	c.wg.Wait()
}
