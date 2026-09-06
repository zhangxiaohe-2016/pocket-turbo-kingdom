export class FixedStep {
  accumulator=0;
  readonly dt=1/60;
  advance(delta:number, step:(dt:number)=>void):number {
    this.accumulator+=Math.min(Math.max(delta,0),0.1);
    while(this.accumulator>=this.dt){step(this.dt);this.accumulator-=this.dt;}
    return this.accumulator/this.dt;
  }
  reset(){this.accumulator=0;}
}
