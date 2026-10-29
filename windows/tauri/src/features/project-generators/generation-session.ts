export interface GenerationForm {
  projectName: string;
  values: Record<string, unknown>;
  edited: string[];
  runtimes: Record<string, { home: string; version: string }>;
}
export interface GenerationRequest {
  pluginId: string;
  generatorId: string;
  packageIdentity: string;
  form: GenerationForm;
  parent: string;
  createGit: boolean;
}
export interface GenerationReview {
  id: string;
  destination: string;
  plan: { steps: unknown[]; usesNetwork: boolean };
  programs: { executable: string; arguments: string[] }[];
}
export interface CreatedProject {
  root: string;
  openFiles: string[];
}
export interface GenerationPort {
  prepare(request: GenerationRequest): Promise<GenerationReview>;
  generate(id: string): Promise<CreatedProject>;
  cancel(id: string): Promise<void>;
}

/** One wizard incarnation owns its review and any late native response. */
export class GenerationSession {
  private epoch = 0;
  private review?: GenerationReview;
  private running = false;
  private retained = false;
  private closed = false;
  constructor(private readonly port: GenerationPort) {}

  async prepare(request: GenerationRequest): Promise<GenerationReview | undefined> {
    if (this.closed || this.running || this.retained) throw new Error("generator.busy");
    const epoch = ++this.epoch;
    const previous = this.review;
    if (previous) {
      await this.port.cancel(previous.id);
      if (this.review === previous) this.review = undefined;
    }
    if (this.closed || epoch !== this.epoch) return undefined;
    const review = await this.port.prepare(request);
    if (this.closed || epoch !== this.epoch) {
      await this.port.cancel(review.id);
      return undefined;
    }
    this.review = review;
    return review;
  }

  async generate(): Promise<CreatedProject> {
    if (this.closed || this.running || this.retained || !this.review)
      throw new Error("generator.stale");
    this.running = true;
    try {
      return await this.port.generate(this.review.id);
    } catch (error) {
      const code =
        error && typeof error === "object" && "code" in error
          ? error.code
          : error instanceof Error
            ? error.message
            : error;
      this.retained = code === "generator.cleanupFailed";
      throw error;
    } finally {
      this.running = false;
      if (!this.retained) this.review = undefined;
    }
  }

  async cancel(): Promise<void> {
    ++this.epoch;
    const review = this.review;
    if (review) {
      await this.port.cancel(review.id);
      if (this.review === review) {
        this.review = undefined;
        this.retained = false;
      }
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    await this.cancel();
  }
}
