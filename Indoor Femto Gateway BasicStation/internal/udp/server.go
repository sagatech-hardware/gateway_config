package udp

import (
	"context"
	crand "crypto/rand"
	"errors"
	"log"
	"net"
	"sync"
)

// Server is the UDP endpoint the gateway's lora_pkt_fwd targets. It ACKs uplinks
// and remembers the forwarder's address so downlinks can be pushed back.
type Server struct {
	addr string
	conn *net.UDPConn

	mu sync.Mutex
	pf *net.UDPAddr // learned packet-forwarder source address

	// OnUplink is called for each CRC-valid rxpk received.
	OnUplink func(RXPacket)
	// OnTxAck is called for each TX_ACK; errStr is "" on success.
	OnTxAck func(token [2]byte, errStr string)
}

func NewServer(addr string) *Server { return &Server{addr: addr} }

// Serve binds the UDP socket and processes packets until ctx is cancelled.
func (s *Server) Serve(ctx context.Context) error {
	ua, err := net.ResolveUDPAddr("udp", s.addr)
	if err != nil {
		return err
	}
	conn, err := net.ListenUDP("udp", ua)
	if err != nil {
		return err
	}
	s.conn = conn
	go func() { <-ctx.Done(); conn.Close() }()

	log.Printf("udp: listening on %s (waiting for lora_pkt_fwd)", s.addr)
	buf := make([]byte, 4096)
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			log.Printf("udp: read: %v", err)
			continue
		}
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		s.handle(pkt, from)
	}
}

func (s *Server) handle(pkt []byte, from *net.UDPAddr) {
	if len(pkt) < 4 || pkt[0] != ProtoVersion {
		return
	}
	switch pkt[3] {
	case PushData:
		s.write(ackFor(pkt, PushAck), from)
		rxs, err := decodePushData(pkt)
		if err != nil {
			log.Printf("udp: bad PUSH_DATA: %v", err)
			return
		}
		for _, rx := range rxs {
			if rx.Stat < 0 { // CRC failed
				continue
			}
			if s.OnUplink != nil {
				s.OnUplink(rx)
			}
		}
	case PullData:
		s.setPF(from)
		s.write(ackFor(pkt, PullAck), from)
	case TxAck:
		token, errStr := decodeTxAck(pkt)
		if errStr != "" {
			log.Printf("udp: TX_ACK error=%s", errStr)
		}
		if s.OnTxAck != nil {
			s.OnTxAck(token, errStr)
		}
	}
}

// SendTX pushes a txpk to the learned packet-forwarder address and returns the
// PULL_RESP token so the caller can correlate the eventual TX_ACK (used for the
// RX1→RX2 fallback).
func (s *Server) SendTX(tx *TXPacket) ([2]byte, error) {
	s.mu.Lock()
	pf, conn := s.pf, s.conn
	s.mu.Unlock()
	var token [2]byte
	if pf == nil || conn == nil {
		return token, errors.New("no packet forwarder registered yet (no PULL_DATA seen)")
	}
	token = randToken()
	pkt, err := encodePullResp(token, tx)
	if err != nil {
		return token, err
	}
	_, err = conn.WriteToUDP(pkt, pf)
	return token, err
}

func (s *Server) setPF(a *net.UDPAddr) {
	s.mu.Lock()
	s.pf = a
	s.mu.Unlock()
}

func (s *Server) write(b []byte, to *net.UDPAddr) {
	if _, err := s.conn.WriteToUDP(b, to); err != nil {
		log.Printf("udp: write: %v", err)
	}
}

func randToken() [2]byte {
	var t [2]byte
	_, _ = crand.Read(t[:])
	return t
}
