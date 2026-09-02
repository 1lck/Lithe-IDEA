export interface RequestGeneration {
  begin: () => number;
  isCurrent: (generation: number) => boolean;
}

export function createRequestGeneration(): RequestGeneration {
  let currentGeneration = 0;

  return {
    begin: () => {
      currentGeneration += 1;
      return currentGeneration;
    },
    isCurrent: (generation) => generation === currentGeneration,
  };
}
