package term

import "errors"

// An inline image is decoded away from the window thread. Unpacking a 4 MP
// picture and copying it to premultiplied BGRA takes tens of milliseconds, and
// a terminal that waited for it in Write would drop frames. The parser queues a
// job instead; ApplyImages applies the finished jobs in parse order on the
// thread that owns the Terminal, so an image's acceptance, placement, deletion
// and reply still happen in the order the bytes asked for them.
type imageJob struct {
	// wake asks the owner for the frame that shows the result. It is called
	// from the decoding goroutine.
	wake func()
	// decode runs off the window thread and must not touch the Terminal.
	decode func() imageResult
	// apply runs on the terminal's thread once every earlier job has been
	// applied.
	apply func(t *Terminal, result imageResult)
	// size is the payload the job holds, for the queue's memory budget.
	size int
	done chan struct{}
	// result is written by the decoding goroutine before done is closed.
	result imageResult
}

type imageResult struct {
	pixels        []byte
	width, height int
	err           error
	// status is the kitty protocol's reply text for a failed decode.
	status string
}

const (
	// imageQueueDepth and imageQueueBytes bound what a program that writes
	// images faster than they decode can make the terminal hold. Past them the
	// image is dropped with an error instead of remembered.
	imageQueueDepth = 8
	imageQueueBytes = 96 << 20
	// imageDecodeParallel bounds the CPU image decoding may use; the window
	// thread and the rest of the program stay responsive.
	imageDecodeParallel = 2
)

var (
	errImageQueueFull    = errors.New("image queue is full")
	errImageSizeMismatch = errors.New("image does not match its declared size")
	errSixelImage        = errors.New("invalid sixel image")
	errKittyCompression  = errors.New("unsupported image compression")
)

// imageDecodeSlots is the process-wide limit on concurrent decodes.
var imageDecodeSlots = make(chan struct{}, imageDecodeParallel)

// startImageDecode runs one job on a helper goroutine. The goroutine ends with
// the job, so a closed terminal does not leave one behind.
func startImageDecode(job *imageJob) {
	go func() {
		imageDecodeSlots <- struct{}{}
		job.result = job.decode()
		<-imageDecodeSlots
		close(job.done)
		if job.wake != nil {
			job.wake()
		}
	}()
}

// SetImageWake installs the callback that asks for the frame showing an image
// decoded off the window thread. It is called from another goroutine, so it
// must be safe there; window invalidation is. Nil leaves the image to the next
// frame the owner draws for another reason.
func (t *Terminal) SetImageWake(wake func()) {
	t.imageWake = wake
}

// queueImageJob puts one image operation in parse order. A job whose decode is
// nil is a state-only operation (a kitty placement or delete) and is ready
// immediately.
func (t *Terminal) queueImageJob(job *imageJob) {
	job.done = make(chan struct{})
	t.imageBytes += job.size
	ready := false
	switch {
	case job.decode == nil:
		// A state-only job (a kitty placement or delete) is ready at once.
		close(job.done)
		ready = true
	case len(t.imageOps) >= imageQueueDepth || t.imageBytes > imageQueueBytes:
		job.result = imageResult{err: errImageQueueFull, status: "ENOMEM:image queue is full"}
		job.decode = nil
		close(job.done)
		ready = true
	default:
		startImageDecode(job)
	}
	t.imageOps = append(t.imageOps, job)
	if ready && t.imageWake != nil {
		// Nothing will decode this job, so nothing else would ask for the frame
		// that applies it and sends its reply.
		t.imageWake()
	}
}

// ApplyImages applies the jobs that have finished, in the order they were
// parsed, and stops at the first one still decoding so nothing overtakes it.
// The terminal's own thread calls it once per frame; it is cheap when nothing
// is pending.
func (t *Terminal) ApplyImages() bool {
	if len(t.imageOps) == 0 {
		return false
	}
	applied, changed := 0, false
	for _, job := range t.imageOps {
		select {
		case <-job.done:
		default:
			goto apply
		}
		applied++
		t.imageBytes -= job.size
		if job.apply != nil {
			job.apply(t, job.result)
			changed = true
		}
	}
apply:
	if applied == 0 {
		return false
	}
	for index := 0; index < applied; index++ {
		t.imageOps[index] = nil
	}
	t.imageOps = t.imageOps[applied:]
	if len(t.imageOps) == 0 {
		t.imageOps, t.imageBytes = nil, 0
	}
	return changed
}

// WaitImages blocks until every queued image has decoded and applies them. It
// is for tests and callers that are not the window thread; the window thread
// must never wait for a decode.
func (t *Terminal) WaitImages() {
	for _, job := range t.imageOps {
		if job.decode != nil {
			<-job.done
		}
	}
	t.ApplyImages()
}

// discardImageJobs drops the pending jobs. A decode already running finishes
// into a result nobody applies.
func (t *Terminal) discardImageJobs() {
	clear(t.imageOps)
	t.imageOps, t.imageBytes = nil, 0
}

// imageAnchor is where an image arriving now would be placed: the identity of
// the cursor's line and its column. Applying the image later must not move an
// image that the text after it already walked past.
func (t *Terminal) imageAnchor() (lineID uint64, column int, ok bool) {
	if t.scr == nil || t.cy < 0 || t.cy >= len(t.scr.lines) {
		return 0, 0, false
	}
	return t.scr.lines[t.cy].id, t.cx, true
}

// hasLine reports whether a line identity still has a row, on either screen or
// in the history. An image anchored to a line that scrolled out and was
// recycled must not be placed.
func (t *Terminal) hasLine(id uint64) bool {
	if id == 0 {
		return false
	}
	for _, s := range []*screen{&t.main, &t.alt} {
		for index := range s.lines {
			if s.lines[index].id == id {
				return true
			}
		}
	}
	for index := 0; index < t.histCount; index++ {
		if t.histAt(index).id == id {
			return true
		}
	}
	return false
}
