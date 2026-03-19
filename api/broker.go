package main

import (
	"sync"
)

// Broker is a simple pub/sub fan-out for SSE event broadcasting.
// The ingest handler pushes events here after successful DB insert;
// SSE subscriber goroutines read from their individual channels.
type Broker struct {
	mu          sync.RWMutex
	subscribers map[chan []Event]struct{}
}

// NewBroker creates a new SSE event broker.
func NewBroker() *Broker {
	return &Broker{
		subscribers: make(map[chan []Event]struct{}),
	}
}

// Subscribe registers a new subscriber and returns a channel that will
// receive event batches. The caller must call Unsubscribe when done.
func (b *Broker) Subscribe() chan []Event {
	ch := make(chan []Event, 16) // buffered to avoid blocking the ingest path
	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

// Unsubscribe removes a subscriber channel and closes it.
func (b *Broker) Unsubscribe(ch chan []Event) {
	b.mu.Lock()
	delete(b.subscribers, ch)
	b.mu.Unlock()
	close(ch)
}

// Broadcast sends a batch of events to all connected subscribers.
// Non-blocking: if a subscriber's buffer is full, the batch is dropped for
// that subscriber (slow consumer protection).
func (b *Broker) Broadcast(events []Event) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	for ch := range b.subscribers {
		select {
		case ch <- events:
		default:
			// Subscriber is slow; drop this batch rather than blocking ingest.
		}
	}
}
